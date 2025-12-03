//
//  ImageStreamController.m
//  camerawesome
//
//  Created by Dimitri Dessus on 17/12/2020.
//

#import "ImageStreamController.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>

@interface ImageStreamController ()

@property(nonatomic, copy) NSString *outputFormat;
@property(nonatomic, strong) CIContext *ciContext;
@property(nonatomic, assign) CGFloat jpegQuality;

@end

@implementation ImageStreamController

NSInteger const MaxPendingProcessedImage = 4;

- (instancetype)initWithStreamImages:(bool)streamImages {
  self = [super init];
  if (self) {
    _streamImages = streamImages;
    _processingImage = 0;
    _outputFormat = @"bgra8888";
    _jpegQuality = 0.7f;
  }
  return self;
}

# pragma mark - Camera Delegates
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection orientation:(UIDeviceOrientation)orientation {
  if (_imageStreamEventSink == nil) {
    return;
  }
  
  bool shouldFPSGuard = [self fpsGuard];
  bool shouldOverflowCrashingGuard = [self overflowCrashingGuard];
  
  if (shouldFPSGuard || shouldOverflowCrashingGuard) {
    return;
  }
  
  _processingImage++;
  
  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  
  size_t imageWidth = CVPixelBufferGetWidth(pixelBuffer);
  size_t imageHeight = CVPixelBufferGetHeight(pixelBuffer);
  NSString *requestedFormat = self.outputFormat ?: @"bgra8888";
  NSDictionary *imageBuffer = nil;
  
  if ([requestedFormat isEqualToString:@"jpeg"]) {
    if (@available(iOS 11.0, *)) {
      CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
      CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
      NSDictionary *options = @{ (__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(self.jpegQuality) };
      NSData *jpegData = [self.ciContext JPEGRepresentationOfImage:ciImage colorSpace:colorSpace options:options];
      CGColorSpaceRelease(colorSpace);
      if (jpegData != nil) {
        imageBuffer = @{
          @"width": [NSNumber numberWithUnsignedLong:imageWidth],
          @"height": [NSNumber numberWithUnsignedLong:imageHeight],
          @"format": @"jpeg",
          @"jpegImage": [FlutterStandardTypedData typedDataWithBytes:jpegData],
          @"cropRect": @{
            @"left": @(0),
            @"top": @(0),
            @"right": [NSNumber numberWithUnsignedLong:imageWidth],
            @"bottom": [NSNumber numberWithUnsignedLong:imageHeight],
          },
          @"rotation": [self getInputImageOrientation:orientation]
        };
      }
    }
  }

  if (imageBuffer == nil) {
    NSMutableArray *planes = [NSMutableArray array];
    const Boolean isPlanar = CVPixelBufferIsPlanar(pixelBuffer);
    size_t planeCount = isPlanar ? CVPixelBufferGetPlaneCount(pixelBuffer) : 1;
    
    for (int i = 0; i < planeCount; i++) {
      void *planeAddress;
      size_t bytesPerRow;
      size_t height;
      size_t width;
      
      if (isPlanar) {
        planeAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, i);
        bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, i);
        height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i);
        width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i);
      } else {
        planeAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
        bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
        height = CVPixelBufferGetHeight(pixelBuffer);
        width = CVPixelBufferGetWidth(pixelBuffer);
      }
      
      NSNumber *length = @(bytesPerRow * height);
      NSData *bytes = [NSData dataWithBytes:planeAddress length:length.unsignedIntegerValue];
      
      [planes addObject:@{
        @"bytesPerRow": @(bytesPerRow),
        @"width": @(width),
        @"height": @(height),
        @"bytes": [FlutterStandardTypedData typedDataWithBytes:bytes],
      }];
    }
    
    imageBuffer = @{
      @"width": [NSNumber numberWithUnsignedLong:imageWidth],
      @"height": [NSNumber numberWithUnsignedLong:imageHeight],
      @"format": @"bgra8888",
      @"planes": planes,
      @"rotation": [self getInputImageOrientation:orientation]
    };
  }
  
  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_imageStreamEventSink(imageBuffer);
  });
  
}

- (NSString *)getInputImageOrientation:(UIDeviceOrientation)orientation {
  switch (orientation) {
    case UIDeviceOrientationLandscapeLeft:
      return @"rotation90deg";
    case UIDeviceOrientationLandscapeRight:
      return @"rotation270deg";
    case UIDeviceOrientationPortrait:
      return @"rotation0deg";
    case UIDeviceOrientationPortraitUpsideDown:
      return @"rotation180deg";
    default:
      return @"rotation0deg";
  }
}

#pragma mark - Guards

- (bool)fpsGuard {
  // calculate time interval between latest emitted frame
  NSDate *nowDate = [NSDate date];
  NSTimeInterval secondsBetween = [nowDate timeIntervalSinceDate:_latestEmittedFrame];
  
  // fps limit check, ignored if nil or == 0
  if (_maxFramesPerSecond && _maxFramesPerSecond > 0) {
    if (secondsBetween <= (1 / _maxFramesPerSecond)) {
      // skip image because out of time
      return YES;
    }
  }
  
  return NO;
}

- (bool)overflowCrashingGuard {
  // overflow crash prevent condition
  if (_processingImage > MaxPendingProcessedImage) {
    // too many frame are pending processing, skipping...
    // this prevent crashing on older phones like iPhone 6, 7...
    return YES;
  }
  
  return NO;
}

// This is used to know the exact time when the image was received on the Flutter part
- (void)receivedImageFromStream {
  // used for the fps limit condition
  _latestEmittedFrame = [NSDate date];
  
  // used for the overflow prevent crashing condition
  if (_processingImage >= 0) {
    _processingImage--;
  }
}

#pragma mark - Setters

- (void)setImageStreamEventSink:(FlutterEventSink)imageStreamEventSink {
  _imageStreamEventSink = imageStreamEventSink;
}

- (void)setMaxFramesPerSecond:(float)maxFramesPerSecond {
  _maxFramesPerSecond = maxFramesPerSecond;
}

- (void)setStreamImages:(bool)streamImages {
  _streamImages = streamImages;
}

- (void)setOutputFormat:(NSString *)format {
  NSString *normalizedFormat = [[format lowercaseString] copy];
  if ([normalizedFormat isEqualToString:@"jpeg"]) {
    _outputFormat = normalizedFormat;
  } else {
    _outputFormat = @"bgra8888";
  }
}

- (CIContext *)ciContext {
  if (_ciContext == nil) {
    _ciContext = [CIContext contextWithOptions:nil];
  }
  return _ciContext;
}

@end
