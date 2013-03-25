//
//  TMSamsungTVManager.m
//  TorrentMonitor
//
//  Created by Mike Godenzi on 24.03.13.
//  Copyright (c) 2013 Mike Godenzi. All rights reserved.
//
//  Permission is given to use this source code file, free of charge, in any
//  project, commercial or otherwise, entirely at your risk, with the condition
//  that any redistribution (in part or whole) of source code must retain
//  this copyright and permission notice. Attribution in compiled projects is
//  appreciated but not required.
//

#import "SamsungTVManager.h"
#import "NSData+Base64.h"
#import <ifaddrs.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import <net/if.h>
#import <net/if_dl.h>

static NSString * const kAppString = @"iphone..iapp.samsung"; // app name reported by the Samsung Remote app
static NSString * const kTVAppStringFMT = @"iphone.%@.iapp.samsung"; // needs to be adapted depending on the TV model

static SamsungTVManager * SharedInstance = nil;

@interface NSString (Base64)
- (NSData *)base64Data;
@end

@implementation NSString (Base64)

- (NSData *)base64Data {
	NSData * selfData = [self dataUsingEncoding:NSUTF8StringEncoding];
	size_t outputLength = 0;
	char * outputBuffer = NewBase64Encode([selfData bytes], [selfData length], true, &outputLength);
	return [NSData dataWithBytesNoCopy:outputBuffer length:outputLength freeWhenDone:YES];
}

@end

@interface SamsungTVManager ()<NSStreamDelegate>

@end

@implementation SamsungTVManager {
	NSInputStream * _inputStream;
	NSOutputStream * _outputStream;

	NSMutableArray * _pending;
	NSString * _tvAppString;
	NSString * _remoteName;

	void(^_onOpen)(void);
}

#pragma mark - Singleton

+ (void)initialize {
    if (!SharedInstance) {
        SharedInstance = [[self alloc] init];
    }
}

+ (SamsungTVManager *)sharedInstance {
    return SharedInstance;
}

+ (id)allocWithZone:(NSZone *)zone {
	id result = nil;
    if (SharedInstance)
        result = SharedInstance;
    else
        result = [super allocWithZone:zone];
	return result;
}

- (id)init {
	if (!SharedInstance) {
		self = [super init];
		SharedInstance = self;
	} else if (self != SharedInstance)
        self = SharedInstance;
	return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

#pragma mark - Public Methods

- (void)connectToAddress:(NSString *)address withTVModel:(NSString *)tvModel remoteName:(NSString *)name completion:(void(^)(void))completion {
	if (_inputStream || _outputStream)
		[self disconnect];
	_onOpen = [completion copy];
	_tvAppString = [NSString stringWithFormat:kTVAppStringFMT, tvModel];
	_remoteName = name;
	CFReadStreamRef readStream;
	CFWriteStreamRef writeStream;
	CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)address, 55000, &readStream, &writeStream);
	_inputStream = (NSInputStream *)CFBridgingRelease(readStream);
	_outputStream = (NSOutputStream *)CFBridgingRelease(writeStream);
	_inputStream.delegate = self;
	_outputStream.delegate = self;
	[_inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	[_outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
	[_inputStream open];
	[_outputStream open];
}

- (void)disconnect {
	if (_inputStream && _outputStream) {
		_tvAppString = nil;
		[_inputStream close];
		[_inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
		_inputStream = nil;
		[_outputStream close];
		[_outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
		_outputStream = nil;
	}
}

- (void)sendRemoteKey:(NSString *)key {
	NSData * tvAppString = [_tvAppString dataUsingEncoding:NSUTF8StringEncoding];
	NSData * base64Key = [key base64Data];
	NSMutableData * envelope = [NSMutableData new];
	NSMutableData * message = [NSMutableData new];
	char separator = 0;
	// mark start of message
	char start[3] = {0, 0, 0};
	[message appendBytes:start length:(sizeof(char) * 3)];
	// append key
	char keyLength = (char)[base64Key length];
	[message appendBytes:&keyLength length:sizeof(char)];
	[message appendBytes:&separator length:sizeof(char)];
	[message appendData:base64Key];
	// envelope
	[envelope appendBytes:&separator length:sizeof(char)];
	// tv app string
	char appStringLength = (char)[tvAppString length];
	[envelope appendBytes:&appStringLength length:sizeof(char)];
	[envelope appendBytes:&separator length:sizeof(char)];
	[envelope appendData:tvAppString];
	// append message
	char messageLength = (char)[message length];
	[envelope appendBytes:&messageLength length:sizeof(char)];
	[envelope appendBytes:&separator length:sizeof(char)];
	[envelope appendData:message];
	[self sendData:envelope];
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)streamEvent {
	switch (streamEvent) {
		case NSStreamEventOpenCompleted: {
			NSLog(@"Stream opened");
			if (stream == _outputStream) {
				[self performHandShake];
				_onOpen();
			}
			break;
		} case NSStreamEventHasBytesAvailable: {
			NSLog(@"Stream has bytes available");
			[self processHasBytesAvailable];
			break;
		} case NSStreamEventHasSpaceAvailable: {
			NSLog(@"Stream has space available");
			[self processHasSpaceAvailable];
			break;
		} case NSStreamEventErrorOccurred: {
			NSLog(@"Stream error occurred");
			[self disconnect];
			break;
		} case NSStreamEventEndEncountered: {
			NSLog(@"Stream end encountered");
			[self disconnect];
			break;
		} default: {
			NSLog(@"Unknown event");
			break;
		}
	}
}

#pragma mark - Private Methods

- (void)processHasBytesAvailable {
	// not really needed
}

- (void)processHasSpaceAvailable {
	dispatch_async(dispatch_get_main_queue(), ^{
		if ([_pending count]) {
			do {
				void(^pending)(void) = (void(^)(void))_pending[0];
				pending();
				[_pending removeObjectAtIndex:0];
			} while ([_outputStream hasSpaceAvailable] && [_pending count]);
		}
	});
}

- (void)performHandShake {
	NSString * ip = [self ipAddress];
	NSString * mac = [self macAddress];
	if (![mac length] || ![ip length])
		[self disconnect];
	else {
		NSData * appString = [kAppString dataUsingEncoding:NSUTF8StringEncoding];
		NSData * base64IP = [ip base64Data];
		NSData * base64MAC = [mac base64Data];
		NSData * base64RemoteName = [_remoteName base64Data];

		NSMutableData * part1 = [NSMutableData new];
		NSMutableData * message1 = [NSMutableData new];
		char separator = 0;
		// mark start of message
		char start[2] = {100, 0};
		[message1 appendBytes:start length:(sizeof(char) * 2)];
		// append ip address
		char ipLength = (char)[base64IP length];
		[message1 appendBytes:&ipLength length:sizeof(char)];
		[message1 appendBytes:&separator length:sizeof(char)];
		[message1 appendData:base64IP];
		// append mac address
		char macLength = (char)[base64MAC length];
		[message1 appendBytes:&macLength length:sizeof(char)];
		[message1 appendBytes:&separator length:sizeof(char)];
		[message1 appendData:base64MAC];
		// append remote name
		char remoteNameLength = (char)[base64RemoteName length];
		[message1 appendBytes:&remoteNameLength length:sizeof(char)];
		[message1 appendBytes:&separator length:sizeof(char)];
		[message1 appendData:base64RemoteName];
		// first part
		[part1 appendBytes:&separator length:sizeof(char)];
		// append app string
		char appStringLength = (char)[appString length];
		[part1 appendBytes:&appStringLength length:sizeof(char)];
		[part1 appendBytes:&separator length:sizeof(char)];
		[part1 appendData:appString];
		// append message
		char message1Length = (char)[message1 length];
		[part1 appendBytes:&message1Length length:sizeof(char)];
		[part1 appendBytes:&separator length:sizeof(char)];
		[part1 appendData:message1];

		[self sendData:part1];

		NSMutableData * part2 = [NSMutableData new];
		// second part
		[part2 appendBytes:&separator length:sizeof(char)];
		// append app string
		[part2 appendBytes:&appStringLength length:sizeof(char)];
		[part2 appendBytes:&separator length:sizeof(char)];
		[part2 appendData:appString];
		// message
		char message2[2] = {200, 0};
		char message2Length = (char)2;
		[part2 appendBytes:&message2Length length:sizeof(char)];
		[part2 appendBytes:&separator length:sizeof(char)];
		[part2 appendBytes:message2 length:(sizeof(char) * 2)];

		[self sendData:part2];
	}
}

- (void)sendData:(NSData *)data {
	dispatch_async(dispatch_get_main_queue(), ^{
		void(^pending)(void) = ^{
			NSInteger bytesWritten = [_outputStream write:[data bytes] maxLength:[data length]];
			if (bytesWritten != [data length]) {
				// do something
				NSLog(@"%i / %i bytes written", bytesWritten, [data length]);
				return;
			}
		};
		if ([_outputStream hasSpaceAvailable])
			pending();
		else
			[_pending addObject:[pending copy]];
	});
}

// from http://stackoverflow.com/questions/7072989/iphone-ipad-how-to-get-my-ip-address-programmatically
- (NSString *)ipAddress {
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    NSString *wifiAddress = nil;
    NSString *cellAddress = nil;

    // retrieve the current interfaces - returns 0 on success
    if(!getifaddrs(&interfaces)) {
        // Loop through linked list of interfaces
        temp_addr = interfaces;
        while(temp_addr != NULL) {
            sa_family_t sa_type = temp_addr->ifa_addr->sa_family;
            if(sa_type == AF_INET || sa_type == AF_INET6) {
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                NSString *addr = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)]; // pdp_ip0
                NSLog(@"NAME: \"%@\" addr: %@", name, addr); // see for yourself
                if([name isEqualToString:@"en0"]) {
                    // Interface is the wifi connection on the iPhone
                    wifiAddress = addr;
                } else
					if([name isEqualToString:@"pdp_ip0"]) {
						// Interface is the cell connection on the iPhone
						cellAddress = addr;
					}
            }
            temp_addr = temp_addr->ifa_next;
        }
        // Free memory
        freeifaddrs(interfaces);
    }
    NSString * addr = wifiAddress ? wifiAddress : cellAddress;
    return addr;
}

// from https://gist.github.com/Coeur/1409855
- (NSString *)macAddress {
    int                 mgmtInfoBase[6];
    char                *msgBuffer = NULL;
    NSString            *errorFlag = NULL;
    size_t              length;

    // Setup the management Information Base (mib)
    mgmtInfoBase[0] = CTL_NET;        // Request network subsystem
    mgmtInfoBase[1] = AF_ROUTE;       // Routing table info
    mgmtInfoBase[2] = 0;
    mgmtInfoBase[3] = AF_LINK;        // Request link layer information
    mgmtInfoBase[4] = NET_RT_IFLIST;  // Request all configured interfaces

    // With all configured interfaces requested, get handle index
    if ((mgmtInfoBase[5] = if_nametoindex("en0")) == 0)
        errorFlag = @"if_nametoindex failure";
    // Get the size of the data available (store in len)
    else if (sysctl(mgmtInfoBase, 6, NULL, &length, NULL, 0) < 0)
        errorFlag = @"sysctl mgmtInfoBase failure";
    // Alloc memory based on above call
    else if ((msgBuffer = malloc(length)) == NULL)
        errorFlag = @"buffer allocation failure";
    // Get system information, store in buffer
    else if (sysctl(mgmtInfoBase, 6, msgBuffer, &length, NULL, 0) < 0)
    {
        free(msgBuffer);
        errorFlag = @"sysctl msgBuffer failure";
    }
    else
    {
        // Map msgbuffer to interface message structure
        struct if_msghdr *interfaceMsgStruct = (struct if_msghdr *) msgBuffer;

        // Map to link-level socket structure
        struct sockaddr_dl *socketStruct = (struct sockaddr_dl *) (interfaceMsgStruct + 1);

        // Copy link layer address data in socket structure to an array
        unsigned char macAddress[6];
        memcpy(&macAddress, socketStruct->sdl_data + socketStruct->sdl_nlen, 6);

        // Read from char array into a string object, into traditional Mac address format
        NSString *macAddressString = [NSString stringWithFormat:@"%02X-%02X-%02X-%02X-%02X-%02X",//@"%02X:%02X:%02X:%02X:%02X:%02X"
                                      macAddress[0], macAddress[1], macAddress[2], macAddress[3], macAddress[4], macAddress[5]];
        NSLog(@"Mac Address: %@", macAddressString);

        // Release the buffer memory
        free(msgBuffer);

        return macAddressString;
    }

    // Error...
    NSLog(@"Error: %@", errorFlag);

    return nil;
}

@end

