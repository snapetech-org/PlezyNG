// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
// Deterministic CPU decoding shared by every native host. No codec/driver
// allocation occurs until the encoded size, dimensions and layout are checked.
// DDS layout: https://learn.microsoft.com/windows/win32/direct3ddds/dx-graphics-dds-pguide
#include "milkrust_image.h"
#include <algorithm>
#include <array>
#include <filesystem>
#include <fstream>
#include <stdexcept>

namespace plezy::visualization::legacy_image {
inline uint32_t Read(const std::vector<uint8_t>& bytes, size_t offset, size_t count) {
  if (count > 4 || offset > bytes.size() || count > bytes.size()-offset)
    throw std::runtime_error("Truncated legacy texture.");
  uint32_t result = 0;
  for (size_t i=0; i<count; ++i) result |= uint32_t(bytes[offset+i]) << (8*i);
  return result;
}
inline MilkRustImage Allocate(uint32_t width, uint32_t height) {
  if (!width || !height || width > 4096 || height > 4096 || uint64_t(width)*height > 8*1024*1024)
    throw std::runtime_error("Legacy texture exceeds the decoded image budget.");
  MilkRustImage image; image.width=width; image.height=height;
  image.rgba.resize(size_t(width)*height*4);
  return image;
}
inline std::array<uint8_t,4> Rgb565(uint32_t value) {
  const uint32_t r=(value>>11)&31, g=(value>>5)&63, b=value&31;
  return {uint8_t((r<<3)|(r>>2)), uint8_t((g<<2)|(g>>4)), uint8_t((b<<3)|(b>>2)), 255};
}
inline uint8_t Channel(uint32_t value, uint32_t mask, uint8_t fallback) {
  if (!mask) return fallback;
  unsigned shift=0; while (!(mask&1)) { mask>>=1; ++shift; }
  if ((uint64_t(mask)+1)&mask) throw std::runtime_error("DDS channel masks must be contiguous.");
  return uint8_t((uint64_t((value>>shift)&mask)*255 + mask/2)/mask);
}
inline MilkRustImage Dds(const std::vector<uint8_t>& bytes) {
  if (bytes.size()<128 || Read(bytes,0,4)!=0x20534444 || Read(bytes,4,4)!=124 || Read(bytes,76,4)!=32 ||
      Read(bytes,24,4)>1 || Read(bytes,28,4)>13 || Read(bytes,112,4)!=0)
    throw std::runtime_error("Unsupported DDS header, cube, volume or mip layout.");
  const uint32_t width=Read(bytes,16,4), height=Read(bytes,12,4);
  const uint32_t flags=Read(bytes,80,4), format=Read(bytes,84,4);
  auto image=Allocate(width,height);
  if (flags&4) {
    // DXT1 (BC1), DXT3 (BC2), DXT5 (BC3). Other DDS encodings are explicit
    // failures, matching the app's import gate rather than rendering garbage.
    const bool bc1=format==0x31545844, bc2=format==0x33545844, bc3=format==0x35545844;
    if (!bc1 && !bc2 && !bc3) throw std::runtime_error("DDS requires DXT1, DXT3 or DXT5 compression.");
    const size_t block_size=bc1?8:16, columns=(width+3)/4, rows=(height+3)/4;
    if (columns*rows*block_size > bytes.size()-128) throw std::runtime_error("Truncated DDS blocks.");
    for (size_t by=0; by<rows; ++by) for (size_t bx=0; bx<columns; ++bx) {
      const size_t offset=128+(by*columns+bx)*block_size, color=offset+(bc1?0:8);
      const uint32_t a=Read(bytes,color,2), b=Read(bytes,color+2,2), selectors=Read(bytes,color+4,4);
      std::array<std::array<uint8_t,4>,4> palette{Rgb565(a),Rgb565(b),{}, {}};
      for (size_t c=0; c<3; ++c) {
        if (a>b || !bc1) {
          palette[2][c]=uint8_t((2*uint32_t(palette[0][c])+palette[1][c])/3);
          palette[3][c]=uint8_t((uint32_t(palette[0][c])+2*palette[1][c])/3);
        } else { palette[2][c]=uint8_t((uint32_t(palette[0][c])+palette[1][c])/2); }
      }
      palette[2][3]=255; palette[3][3]=(a>b || !bc1)?255:0;
      std::array<uint8_t,8> alpha{};
      uint64_t alpha_selectors=0;
      if (bc3) {
        alpha[0]=bytes[offset]; alpha[1]=bytes[offset+1];
        const unsigned denominator=alpha[0]>alpha[1]?7:5;
        for (unsigned i=1; i<denominator; ++i)
          alpha[i+1]=uint8_t(((denominator-i)*uint32_t(alpha[0])+i*alpha[1])/denominator);
        if (denominator==5) { alpha[6]=0; alpha[7]=255; }
        for (size_t i=0; i<6; ++i) alpha_selectors |= uint64_t(bytes[offset+2+i]) << (8*i);
      }
      for (size_t i=0; i<16; ++i) {
        const size_t x=bx*4+i%4, y=by*4+i/4;
        if (x>=width || y>=height) continue;
        auto pixel=palette[(selectors>>(2*i))&3];
        if (bc2) pixel[3]=uint8_t(((bytes[offset+i/2]>>(4*(i%2)))&15)*17);
        if (bc3) pixel[3]=alpha[(alpha_selectors>>(3*i))&7];
        std::copy(pixel.begin(),pixel.end(),image.rgba.begin()+(y*width+x)*4);
      }
    }
  } else {
    const uint32_t bits=Read(bytes,88,4);
    if (!(flags&64) || (bits!=24 && bits!=32)) throw std::runtime_error("DDS requires 24/32-bit RGB or DXT compression.");
    std::array<uint32_t,4> masks{Read(bytes,92,4),Read(bytes,96,4),Read(bytes,100,4),Read(bytes,104,4)};
    uint32_t used=0;
    for (size_t c=0; c<4; ++c) {
      if ((!masks[c] && c<3) || (used&masks[c]) || (bits==24 && (masks[c]&0xff000000)))
        throw std::runtime_error("Invalid DDS channel mask.");
      Channel(0,masks[c],0); used|=masks[c];
    }
    const size_t tight=size_t(width)*(bits/8);
    const size_t pitch=(Read(bytes,8,4)&8)?Read(bytes,20,4):tight;
    if (pitch<tight || pitch>16*1024*1024 || pitch>(bytes.size()-128)/height)
      throw std::runtime_error("Truncated DDS row layout.");
    for (size_t y=0; y<height; ++y) for (size_t x=0; x<width; ++x) {
      const auto value=Read(bytes,128+y*pitch+x*(bits/8),bits/8);
      for (size_t c=0; c<4; ++c) image.rgba[(y*width+x)*4+c]=Channel(value,masks[c],c==3?255:0);
    }
  }
  return image;
}
inline MilkRustImage Tga(const std::vector<uint8_t>& bytes) {
  if (bytes.size()<18 || bytes[1]!=0 || (bytes[17]&0xc0)) throw std::runtime_error("Unsupported TGA header.");
  const uint8_t type=bytes[2], bits=bytes[16], descriptor=bytes[17];
  const bool gray=type==3 || type==11, rle=type==10 || type==11;
  if ((!gray && type!=2 && type!=10) || (gray?bits!=8 && bits!=16:bits!=16 && bits!=24 && bits!=32))
    throw std::runtime_error("TGA requires truecolor or grayscale pixels.");
  auto image=Allocate(Read(bytes,12,2),Read(bytes,14,2));
  size_t offset=18+bytes[0], cursor=0;
  const size_t count=size_t(image.width)*image.height, pixel_bytes=bits/8;
  auto pixel = [&]() {
    const uint32_t value=Read(bytes,offset,pixel_bytes); offset+=pixel_bytes;
    std::array<uint8_t,4> p{};
    if (gray) p={uint8_t(value),uint8_t(value),uint8_t(value),uint8_t(bits==16?value>>8:255)};
    else if (bits==16) p={uint8_t(((value>>10)&31)*255/31),uint8_t(((value>>5)&31)*255/31),uint8_t((value&31)*255/31),uint8_t((descriptor&15)?((value&0x8000)?255:0):255)};
    else p={uint8_t(value>>16),uint8_t(value>>8),uint8_t(value),uint8_t(bits==32 && (descriptor&15)?value>>24:255)};
    return p;
  };
  while (cursor<count) {
    const uint32_t header=rle?Read(bytes,offset++,1):0;
    const size_t run=rle?(header&127)+1:1;
    if (run>count-cursor) throw std::runtime_error("TGA run exceeds its image.");
    std::array<uint8_t,4> repeated{};
    if (header&128) repeated=pixel();
    for (size_t i=0; i<run; ++i,++cursor) {
      const auto p=(header&128)?repeated:pixel();
      const size_t x=(descriptor&16)?image.width-1-cursor%image.width:cursor%image.width;
      const size_t y=(descriptor&32)?cursor/image.width:image.height-1-cursor/image.width;
      std::copy(p.begin(),p.end(),image.rgba.begin()+(y*image.width+x)*4);
    }
  }
  return image;
}
inline MilkRustImage Decode(const std::filesystem::path& path, bool dds) {
  const auto size=std::filesystem::file_size(path);
  if (!size || size>16*1024*1024) throw std::runtime_error("Legacy texture exceeds the encoded image budget.");
  std::vector<uint8_t> bytes(static_cast<size_t>(size));
  std::ifstream input(path,std::ios::binary);
  if (!input.read(reinterpret_cast<char*>(bytes.data()),static_cast<std::streamsize>(bytes.size())) || input.peek()!=EOF)
    throw std::runtime_error("Legacy texture changed while loading.");
  return dds?Dds(bytes):Tga(bytes);
}
}  // namespace plezy::visualization::legacy_image
