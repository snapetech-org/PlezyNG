// SPDX-License-Identifier: GPL-3.0-or-later
// Compile against each real SDK; tvOS must eliminate capture APIs entirely.
#import <TargetConditionals.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#include "SteamAppleMicrophone.h"

void plezySteamSdkProbe(CAMetalLayer* layer, CVPixelBufferRef pixelBuffer) {
  layer.pixelFormat = MTLPixelFormatRGBA16Float;
  if (@available(macOS 10.15, iOS 16.0, tvOS 16.0, *)) {
    layer.wantsExtendedDynamicRangeContent = YES;
    layer.EDRMetadata = [CAEDRMetadata HDR10MetadataWithMinLuminance:0
                                                    maxLuminance:1000
                                              opticalOutputScale:100];
  }
  CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                        kCVAttachmentMode_ShouldPropagate);
}
