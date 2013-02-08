//
//  OGImageCache.m
//
//  Created by Art Gillespie on 11/27/12.
//  Copyright (c) 2012 Origami Labs, Inc.. All rights reserved.
//

#import "OGImageCache.h"
#import "OGImage.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>

static OGImageCache *OGImageCacheShared;

NSString *OGImageCachePath() {
    // generate the cache path: <app>/Library/Application Support/<bundle identifier>/OGImageCache,
    // creating the directories as needed
    NSArray *array = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (nil == array || 0 == [array count]) {
        return nil;
    }
    NSString *cachePath = [[array[0] stringByAppendingPathComponent:[[NSBundle mainBundle] bundleIdentifier]] stringByAppendingPathComponent:@"OGImageCache"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cachePath withIntermediateDirectories:YES attributes:nil error:nil];
    return cachePath;
}

@implementation OGImageCache {
    NSCache *_memoryCache;
    dispatch_queue_t _cacheFileTasksQueue;
}

+ (OGImageCache *)shared {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        OGImageCacheShared = [[OGImageCache alloc] init];
    });
    return OGImageCacheShared;
}

+ (NSString *)MD5:(NSString *)string {
    const char *d = [string UTF8String];
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(d, strlen(d), r);
    NSMutableString *hexString = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH];
    for (int ii = 0; ii < CC_MD5_DIGEST_LENGTH; ++ii) {
        [hexString appendFormat:@"%02x", r[ii]];
    }
    return [NSString stringWithString:hexString];
}

+ (NSString *)filePathForKey:(NSString *)key {
    return [OGImageCachePath() stringByAppendingPathComponent:[OGImageCache MD5:key]];
}

- (id)init {
    self = [super init];
    if (self) {
        _memoryCache = [[NSCache alloc] init];
        [_memoryCache setName:@"com.origamilabs.OGImageCache"];
        _cacheFileTasksQueue = dispatch_queue_create("com.origamilabs.OGImageCache.filetasks", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_cacheFileTasksQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    }
    return self;
}

- (void)imageForKey:(NSString *)key block:(OGImageCacheCompletionBlock)block {
    NSParameterAssert(nil != key);
    NSParameterAssert(nil != block);
    __OGImage *image = [_memoryCache objectForKey:key];
    if (nil != image) {
        block(image);
        return;
    }
    dispatch_async(_cacheFileTasksQueue, ^{
        // Check to see if the image is cached locally
        NSString *cachePath = [OGImageCache filePathForKey:(key)];
        __OGImage *image = [[__OGImage alloc] initWithDataAtURL:[NSURL fileURLWithPath:cachePath]];
        // if we have the image in the on-disk cache, store it to the in-memory cache
        if (nil != image) {
            [_memoryCache setObject:image forKey:key];
        }
        // calls the block with the image if it was cached or nil if it wasn't
        dispatch_async(dispatch_get_main_queue(), ^{
            block(image);
        });
    });
}

- (void)setImage:(__OGImage *)image forKey:(NSString *)key {
    NSParameterAssert(nil != image);
    NSParameterAssert(nil != key);
    [_memoryCache setObject:image forKey:key];
    dispatch_async(_cacheFileTasksQueue, ^{
        NSURL *fileURL = [NSURL fileURLWithPath:[OGImageCache filePathForKey:key]];
        NSError *error;
        if(![image writeToURL:fileURL error:&error]) {
            NSLog(@"[OGImageCache ERROR] failed to write image with error %@ %s %d", error, __FILE__, __LINE__);
            return;
        }
    });
}

- (void)purgeCache:(BOOL)wait {
    [_memoryCache removeAllObjects];
    void (^purgeFilesBlock)(void) = ^{
        NSString *cachePath = OGImageCachePath();
        for (NSString *file in [[NSFileManager defaultManager] enumeratorAtPath:cachePath]) {
            [[NSFileManager defaultManager] removeItemAtPath:[cachePath stringByAppendingPathComponent:file] error:nil];
        }
    };
    if (YES == wait) {
        dispatch_sync(_cacheFileTasksQueue, purgeFilesBlock);
    } else {
        dispatch_async(_cacheFileTasksQueue, purgeFilesBlock);
    }
}

- (void)purgeCacheForKey:(NSString *)key andWait:(BOOL)wait {
    NSParameterAssert(nil != key);

    [self purgeMemoryCacheForKey:key andWait:wait];

    NSString *cachedFilePath = [[self class] filePathForKey:key];
    
    void (^purgeFileBlock)(void) =^{
        [[NSFileManager defaultManager] removeItemAtPath:cachedFilePath error:nil];
    };
    
    if (YES == wait) {
        dispatch_sync(_cacheFileTasksQueue, purgeFileBlock);
    } else {
        dispatch_async(_cacheFileTasksQueue, purgeFileBlock);
    }
}

- (void)purgeMemoryCacheForKey:(NSString *)key andWait:(BOOL)wait {
    NSParameterAssert(nil != key);

    [_memoryCache removeObjectForKey:key];
}

@end
