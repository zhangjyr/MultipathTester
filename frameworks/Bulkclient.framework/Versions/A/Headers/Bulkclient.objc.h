// Objective-C API for talking to bitbucket.org/qdeconinck/quic-traffic/bulk/bulkclient Go package.
//   gobind -lang=objc bitbucket.org/qdeconinck/quic-traffic/bulk/bulkclient
//
// File is generated by gobind. Do not edit.

#ifndef __Bulkclient_H__
#define __Bulkclient_H__

@import Foundation;
#include "Universe.objc.h"


FOUNDATION_EXPORT NSString* BulkclientRun(BOOL cache, BOOL multipath, NSString* output, NSString* url);

#endif
