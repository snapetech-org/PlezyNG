// SPDX-License-Identifier: AGPL-3.0-only
#include "../../shared/visualization/legacy_image_decode.h"
#include <iostream>
using namespace plezy::visualization::legacy_image;
namespace {
void Require(bool condition) { if (!condition) throw std::runtime_error("Legacy image regression failed."); }
void U32(std::vector<uint8_t>& bytes, size_t offset, uint32_t value) {
  for (size_t i=0; i<4; ++i) bytes.at(offset+i)=uint8_t(value>>(8*i));
}
std::vector<uint8_t> DdsBlock(uint32_t format, size_t block_size, uint32_t width=4, uint32_t height=4) {
  std::vector<uint8_t> bytes(128+block_size);
  U32(bytes,0,0x20534444); U32(bytes,4,124); U32(bytes,12,height); U32(bytes,16,width);
  U32(bytes,76,32); U32(bytes,80,4); U32(bytes,84,format); return bytes;
}
template<class F> void Reject(F operation) {
  bool rejected=false; try { operation(); } catch (const std::runtime_error&) { rejected=true; }
  Require(rejected);
}
}
int main() {
  try {
    auto bc1=DdsBlock(0x31545844,8,3,2);
    // c0=red565, c1=green565, selectors all c0; partial edge blocks crop.
    bc1[128]=0; bc1[129]=0xf8; bc1[130]=0xe0; bc1[131]=7;
    auto image=Dds(bc1); Require(image.width==3 && image.height==2 && image.rgba.size()==24);
    for (size_t i=0; i<image.rgba.size(); i+=4)
      Require(image.rgba[i]==255 && image.rgba[i+1]==0 && image.rgba[i+2]==0 && image.rgba[i+3]==255);
    // The transparent fourth color exists only in BC1's c0<=c1 mode.
    bc1[128]=0; bc1[129]=0; U32(bc1,132,0xffffffff);
    Require(Dds(bc1).rgba[3]==0);
    auto bc2=DdsBlock(0x33545844,16);
    std::fill(bc2.begin()+128,bc2.begin()+136,0x88);
    bc2[138]=0xff; bc2[139]=0xff; U32(bc2,140,0xffffffff);
    image=Dds(bc2); Require(image.rgba[3]==136 && image.rgba[0]==170);
    auto bc3=DdsBlock(0x35545844,16);
    bc3[128]=20; bc3[129]=100; bc3[130]=7;  // 6-alpha mode selector 7 is opaque.
    Require(Dds(bc3).rgba[3]==255);
    bc3[128]=255; bc3[129]=0; bc3[130]=2;  // 8-alpha mode interpolates 6/7.
    Require(Dds(bc3).rgba[3]==218);
    auto rgb=DdsBlock(0,8,1,2);
    U32(rgb,8,8); U32(rgb,20,4); U32(rgb,80,64); U32(rgb,88,24);
    U32(rgb,92,0xff0000); U32(rgb,96,0xff00); U32(rgb,100,0xff);
    rgb[128]=3; rgb[129]=2; rgb[130]=1; rgb[132]=6; rgb[133]=5; rgb[134]=4;
    image=Dds(rgb); Require(image.rgba[0]==1 && image.rgba[4]==4 && image.rgba[7]==255);
    U32(rgb,96,0xff0000); Reject([&] { Dds(rgb); });
    bc1.resize(131); Reject([&] { Dds(bc1); });
    auto oversized=DdsBlock(0x31545844,8); U32(oversized,16,0xffffffff);
    Reject([&] { Dds(oversized); });
    auto cube=DdsBlock(0x31545844,8); U32(cube,112,512); Reject([&] { Dds(cube); });
    std::vector<uint8_t> tga(18); tga[2]=10; tga[12]=2; tga[14]=1; tga[16]=24; tga[17]=0x30;
    tga.insert(tga.end(),{1,0,0,255,0,255,0});  // raw packet, right-to-left origin
    image=Tga(tga); Require(image.rgba[0]==0 && image.rgba[1]==255 && image.rgba[4]==255);
    tga.resize(18); tga.insert(tga.end(),{0x81,255,0,0}); // two repeated blue pixels
    image=Tga(tga); Require(image.rgba[2]==255 && image.rgba[6]==255);
    tga[18]=0x82; Reject([&] { Tga(tga); });
    tga.resize(10); Reject([&] { Tga(tga); });
    std::cout << "Legacy image decoder regressions passed\n";
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
