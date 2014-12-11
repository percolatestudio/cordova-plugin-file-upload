/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.

 * Modified by Percolate Studio to support 
 * non-multipart uploads.
*/

#import <Cordova/CDV.h>
#import "PSFileUpload.h"
#import "CDVFile.h"

#import <AssetsLibrary/ALAsset.h>
#import <AssetsLibrary/ALAssetRepresentation.h>
#import <AssetsLibrary/ALAssetsLibrary.h>
#import <CFNetwork/CFNetwork.h>

@interface PSFileUpload ()
// Sets the requests headers for the request.
- (void)applyRequestHeaders:(NSDictionary*)headers toRequest:(NSMutableURLRequest*)req;
// Creates a delegate to handle an upload.
- (PSFileUploadDelegate*)delegateForUploadCommand:(CDVInvokedUrlCommand*)command;
// Creates an NSData* for the file for the given upload arguments.
- (void)fileDataForUploadCommand:(CDVInvokedUrlCommand*)command;
@end

// Buffer size to use for streaming uploads.
static const NSUInteger kPSUStreamBufferSize = 32768;
// Magic value within the options dict used to set a cookie.
NSString* const kPSUOptionsKeyCookie = @"__cookie";
// Form boundary for multi-part requests.
NSString* const kPSUFormBoundary = @"+++++org.apache.cordova.formBoundary";

// Writes the given data to the stream in a blocking way.
// If successful, returns bytesToWrite.
// If the stream was closed on the other end, returns 0.
// If there was an error, returns -1.
static CFIndex WriteDataToStream(NSData* data, CFWriteStreamRef stream)
{
    UInt8* bytes = (UInt8*)[data bytes];
    long long bytesToWrite = [data length];
    long long totalBytesWritten = 0;

    while (totalBytesWritten < bytesToWrite) {
        CFIndex result = CFWriteStreamWrite(stream,
                bytes + totalBytesWritten,
                bytesToWrite - totalBytesWritten);
        if (result < 0) {
            CFStreamError error = CFWriteStreamGetError(stream);
            NSLog(@"WriteStreamError domain: %ld error: %ld", error.domain, error.error);
            return result;
        } else if (result == 0) {
            return result;
        }
        totalBytesWritten += result;
    }

    return totalBytesWritten;
}

@implementation PSFileUpload
@synthesize activeTransfers;

- (NSString*)escapePathComponentForUrlString:(NSString*)urlString
{
    NSRange schemeAndHostRange = [urlString rangeOfString:@"://.*?/" options:NSRegularExpressionSearch];

    if (schemeAndHostRange.length == 0) {
        return urlString;
    }

    NSInteger schemeAndHostEndIndex = NSMaxRange(schemeAndHostRange);
    NSString* schemeAndHost = [urlString substringToIndex:schemeAndHostEndIndex];
    NSString* pathComponent = [urlString substringFromIndex:schemeAndHostEndIndex];
    pathComponent = [pathComponent stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

    return [schemeAndHost stringByAppendingString:pathComponent];
}

- (void)applyRequestHeaders:(NSDictionary*)headers toRequest:(NSMutableURLRequest*)req
{
    [req setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];

    NSString* userAgent = [self.commandDelegate userAgent];
    if (userAgent) {
        [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }

    for (NSString* headerName in headers) {
        id value = [headers objectForKey:headerName];
        if (!value || (value == [NSNull null])) {
            value = @"null";
        }

        // First, remove an existing header if one exists.
        [req setValue:nil forHTTPHeaderField:headerName];

        if (![value isKindOfClass:[NSArray class]]) {
            value = [NSArray arrayWithObject:value];
        }

        // Then, append all header values.
        for (id __strong subValue in value) {
            // Convert from an NSNumber -> NSString.
            if ([subValue respondsToSelector:@selector(stringValue)]) {
                subValue = [subValue stringValue];
            }
            if ([subValue isKindOfClass:[NSString class]]) {
                [req addValue:subValue forHTTPHeaderField:headerName];
            }
        }
    }
}

- (NSURLRequest*)requestForUploadCommand:(CDVInvokedUrlCommand*)command fileData:(NSData*)fileData
{
    // arguments order from js: [filePath, server, fileKey, fileName, mimeType, params, debug, chunkedMode]
    // however, params is a JavaScript object and during marshalling is put into the options dict,
    // thus debug and chunkedMode are the 6th and 7th arguments
    NSString* target = [command argumentAtIndex:0];
    NSString* server = [command argumentAtIndex:1];
    NSString* mimeType = [command argumentAtIndex:4 withDefault:nil];
    NSDictionary* options = [command argumentAtIndex:5 withDefault:nil];
    //    BOOL trustAllHosts = [[arguments objectAtIndex:6 withDefault:[NSNumber numberWithBool:YES]] boolValue]; // allow self-signed certs
    BOOL chunkedMode = [[command argumentAtIndex:7 withDefault:[NSNumber numberWithBool:YES]] boolValue];
    NSDictionary* headers = [command argumentAtIndex:8 withDefault:nil];
    // Allow alternative http method, default to POST. JS side checks
    // for allowed methods, currently PUT or POST (forces POST for
    // unrecognised values)
    NSString* httpMethod = [command argumentAtIndex:10 withDefault:@"POST"];
    CDVPluginResult* result = nil;
    PSFileUploadError errorCode = 0;

    // NSURL does not accepts URLs with spaces in the path. We escape the path in order
    // to be more lenient.
    NSURL* url = [NSURL URLWithString:server];

    if (!url) {
        errorCode = INVALID_URL_ERR;
        NSLog(@"File Transfer Error: Invalid server URL %@", server);
    } else if (!fileData) {
        errorCode = FILE_NOT_FOUND_ERR;
    }

    if (errorCode > 0) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:errorCode AndSource:target AndTarget:server]];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return nil;
    }

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url];

    [req setHTTPMethod:httpMethod];

    //    Magic value to set a cookie
    if ([options objectForKey:kPSUOptionsKeyCookie]) {
        [req setValue:[options objectForKey:kPSUOptionsKeyCookie] forHTTPHeaderField:@"Cookie"];
        [req setHTTPShouldHandleCookies:NO];
    }

    if (mimeType) {
        [req setValue:mimeType forHTTPHeaderField:@"Content-Type"];
    } else {
        [req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    }

    [self applyRequestHeaders:headers toRequest:req];

    DLog(@"fileData length: %d", [fileData length]);

    long long totalPayloadLength = [fileData length];
    [req setValue:[[NSNumber numberWithLongLong:totalPayloadLength] stringValue] forHTTPHeaderField:@"Content-Length"];

    if (chunkedMode) {
        CFReadStreamRef readStream = NULL;
        CFWriteStreamRef writeStream = NULL;
        CFStreamCreateBoundPair(NULL, &readStream, &writeStream, kPSUStreamBufferSize);
        [req setHTTPBodyStream:CFBridgingRelease(readStream)];

        self.backgroundTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
                [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskID];
                self.backgroundTaskID = UIBackgroundTaskInvalid;
                NSLog(@"Background task to upload media finished.");
            }];

        [self.commandDelegate runInBackground:^{
            if (CFWriteStreamOpen(writeStream)) {
                NSData* chunks[] = {fileData};
                int numChunks = sizeof(chunks) / sizeof(chunks[0]);

                for (int i = 0; i < numChunks; ++i) {
                    CFIndex result = WriteDataToStream(chunks[i], writeStream);
                    if (result <= 0) {
                        break;
                    }
                }
            } else {
                NSLog(@"FileTransfer: Failed to open writeStream");
            }
            CFWriteStreamClose(writeStream);
            CFRelease(writeStream);
        }];
    } else {
        [req setHTTPBody:fileData];
    }
    return req;
}

- (PSFileUploadDelegate*)delegateForUploadCommand:(CDVInvokedUrlCommand*)command
{
    NSString* source = [command.arguments objectAtIndex:0];
    NSString* server = [command.arguments objectAtIndex:1];
    BOOL trustAllHosts = [[command.arguments objectAtIndex:6 withDefault:[NSNumber numberWithBool:YES]] boolValue]; // allow self-signed certs
    NSString* objectId = [command.arguments objectAtIndex:9];

    PSFileUploadDelegate* delegate = [[PSFileUploadDelegate alloc] init];

    delegate.command = self;
    delegate.callbackId = command.callbackId;
    delegate.objectId = objectId;
    delegate.source = source;
    delegate.target = server;
    delegate.trustAllHosts = trustAllHosts;

    return delegate;
}

- (void)fileDataForUploadCommand:(CDVInvokedUrlCommand*)command
{
    NSString* source = (NSString*)[command.arguments objectAtIndex:0];
    NSString* server = [command.arguments objectAtIndex:1];
    NSError* __autoreleasing err = nil;

    // return unsupported result for assets-library URLs
    if ([source hasPrefix:kCDVAssetsLibraryPrefix]) {
        // Instead, we return after calling the asynchronous method and send `result` in each of the blocks.
        ALAssetsLibraryAssetForURLResultBlock resultBlock = ^(ALAsset* asset) {
            if (asset) {
                // We have the asset!  Get the data and send it off.
                ALAssetRepresentation* assetRepresentation = [asset defaultRepresentation];
                Byte* buffer = (Byte*)malloc([assetRepresentation size]);
                NSUInteger bufferSize = [assetRepresentation getBytes:buffer fromOffset:0.0 length:[assetRepresentation size] error:nil];
                NSData* fileData = [NSData dataWithBytesNoCopy:buffer length:bufferSize freeWhenDone:YES];
                [self uploadData:fileData command:command];
            } else {
                // We couldn't find the asset.  Send the appropriate error.
                CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:NOT_FOUND_ERR AndSource:source AndTarget:server]];
                [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            }
        };
        ALAssetsLibraryAccessFailureBlock failureBlock = ^(NSError* error) {
            // Retrieving the asset failed for some reason.  Send the appropriate error.
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[error localizedDescription]];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        };

        ALAssetsLibrary* assetsLibrary = [[ALAssetsLibrary alloc] init];
        [assetsLibrary assetForURL:[NSURL URLWithString:source] resultBlock:resultBlock failureBlock:failureBlock];
        return;
    } else {
        // Extract the path part out of a file: URL.
        NSString* filePath = [source hasPrefix:@"/"] ? [source copy] : [[NSURL URLWithString:source] path];
        if (filePath == nil) {
            // We couldn't find the asset.  Send the appropriate error.
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:NOT_FOUND_ERR AndSource:source AndTarget:server]];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }

        // Memory map the file so that it can be read efficiently even if it is large.
        NSData* fileData = [NSData dataWithContentsOfFile:filePath options:NSDataReadingMappedIfSafe error:&err];

        if (err != nil) {
            NSLog(@"Error opening file %@: %@", source, err);
        }
        [self uploadData:fileData command:command];
    }
}

- (void)upload:(CDVInvokedUrlCommand*)command
{
    // fileData and req are split into helper functions to ease the unit testing of delegateForUpload.
    // First, get the file data.  This method will call `uploadData:command`.
    [self fileDataForUploadCommand:command];
}

- (void)uploadData:(NSData*)fileData command:(CDVInvokedUrlCommand*)command
{
    NSURLRequest* req = [self requestForUploadCommand:command fileData:fileData];

    if (req == nil) {
        return;
    }
    PSFileUploadDelegate* delegate = [self delegateForUploadCommand:command];
    [NSURLConnection connectionWithRequest:req delegate:delegate];

    if (activeTransfers == nil) {
        activeTransfers = [[NSMutableDictionary alloc] init];
    }

    [activeTransfers setObject:delegate forKey:delegate.objectId];
}

- (void)abort:(CDVInvokedUrlCommand*)command
{
    NSString* objectId = [command.arguments objectAtIndex:0];

    PSFileUploadDelegate* delegate = [activeTransfers objectForKey:objectId];

    if (delegate != nil) {
        [delegate cancelTransfer:delegate.connection];
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:CONNECTION_ABORTED AndSource:delegate.source AndTarget:delegate.target]];
        [self.commandDelegate sendPluginResult:result callbackId:delegate.callbackId];
    }
}

- (NSMutableDictionary*)createFileTransferError:(int)code AndSource:(NSString*)source AndTarget:(NSString*)target
{
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity:3];

    [result setObject:[NSNumber numberWithInt:code] forKey:@"code"];
    if (source != nil) {
        [result setObject:source forKey:@"source"];
    }
    if (target != nil) {
        [result setObject:target forKey:@"target"];
    }
    NSLog(@"FileTransferError %@", result);

    return result;
}

- (NSMutableDictionary*)createFileTransferError:(int)code
                                      AndSource:(NSString*)source
                                      AndTarget:(NSString*)target
                                  AndHttpStatus:(int)httpStatus
                                        AndBody:(NSString*)body
{
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity:5];

    [result setObject:[NSNumber numberWithInt:code] forKey:@"code"];
    if (source != nil) {
        [result setObject:source forKey:@"source"];
    }
    if (target != nil) {
        [result setObject:target forKey:@"target"];
    }
    [result setObject:[NSNumber numberWithInt:httpStatus] forKey:@"http_status"];
    if (body != nil) {
        [result setObject:body forKey:@"body"];
    }
    NSLog(@"FileTransferError %@", result);

    return result;
}

- (void)onReset
{
    for (PSFileUploadDelegate* delegate in [activeTransfers allValues]) {
        [delegate.connection cancel];
    }

    [activeTransfers removeAllObjects];
}

@end

@interface PSFileUploadEntityLengthRequest : NSObject {
    NSURLConnection* _connection;
    PSFileUploadDelegate* __weak _originalDelegate;
}

- (PSFileUploadEntityLengthRequest*)initWithOriginalRequest:(NSURLRequest*)originalRequest andDelegate:(PSFileUploadDelegate*)originalDelegate;

@end;

@implementation PSFileUploadEntityLengthRequest;

- (PSFileUploadEntityLengthRequest*)initWithOriginalRequest:(NSURLRequest*)originalRequest andDelegate:(PSFileUploadDelegate*)originalDelegate
{
    if (self) {
        DLog(@"Requesting entity length for GZIPped content...");

        NSMutableURLRequest* req = [originalRequest mutableCopy];
        [req setHTTPMethod:@"HEAD"];
        [req setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

        _originalDelegate = originalDelegate;
        _connection = [NSURLConnection connectionWithRequest:req delegate:self];
    }
    return self;
}

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSURLResponse*)response
{
    DLog(@"HEAD request returned; content-length is %lld", [response expectedContentLength]);
    [_originalDelegate updateBytesExpected:[response expectedContentLength]];
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)data
{}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{}

@end

@implementation PSFileUploadDelegate

@synthesize callbackId, connection = _connection, source, target, responseData, command, bytesTransfered, bytesExpected, responseCode, objectId, targetFileHandle;

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{
    NSString* uploadResponse = nil;
    NSMutableDictionary* uploadResult;
    CDVPluginResult* result = nil;

    NSLog(@"File Transfer Finished with response code %d", self.responseCode);

    uploadResponse = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];

    if ((self.responseCode >= 200) && (self.responseCode < 300)) {
        // create dictionary to return FileUploadResult object
        uploadResult = [NSMutableDictionary dictionaryWithCapacity:3];
        if (uploadResponse != nil) {
            [uploadResult setObject:uploadResponse forKey:@"response"];
        }
        [uploadResult setObject:[NSNumber numberWithLongLong:self.bytesTransfered] forKey:@"bytesSent"];
        [uploadResult setObject:[NSNumber numberWithInt:self.responseCode] forKey:@"responseCode"];
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:uploadResult];
    } else {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[command createFileTransferError:CONNECTION_ERR AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:uploadResponse]];
    }

    [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];

    // remove connection for activeTransfers
    [command.activeTransfers removeObjectForKey:objectId];

    // remove background id task in case our upload was done in the background
    [[UIApplication sharedApplication] endBackgroundTask:self.command.backgroundTaskID];
    self.command.backgroundTaskID = UIBackgroundTaskInvalid;
}

- (void)removeTargetFile
{
    NSFileManager* fileMgr = [NSFileManager defaultManager];

    [fileMgr removeItemAtPath:self.target error:nil];
}

- (void)cancelTransfer:(NSURLConnection*)connection
{
    [connection cancel];
    [self.command.activeTransfers removeObjectForKey:self.objectId];
    [self removeTargetFile];
}

- (void)cancelTransferWithError:(NSURLConnection*)connection errorMessage:(NSString*)errorMessage
{
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsDictionary:[self.command createFileTransferError:FILE_NOT_FOUND_ERR AndSource:self.source AndTarget:self.target AndHttpStatus:self.responseCode AndBody:errorMessage]];

    NSLog(@"File Transfer Error: %@", errorMessage);
    [self cancelTransfer:connection];
    [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSURLResponse*)response
{
    NSError* __autoreleasing error = nil;

    self.mimeType = [response MIMEType];
    self.targetFileHandle = nil;

    // required for iOS 4.3, for some reason; response is
    // a plain NSURLResponse, not the HTTP subclass
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;

        self.responseCode = [httpResponse statusCode];
        self.bytesExpected = [response expectedContentLength];
    } else if ([response.URL isFileURL]) {
        NSDictionary* attr = [[NSFileManager defaultManager] attributesOfItemAtPath:[response.URL path] error:nil];
        self.responseCode = 200;
        self.bytesExpected = [attr[NSFileSize] longLongValue];
    } else {
        self.responseCode = 200;
        self.bytesExpected = NSURLResponseUnknownLength;
    }
}

- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError*)error
{
    NSString* body = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[command createFileTransferError:CONNECTION_ERR AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:body]];

    NSLog(@"File Transfer Error: %@", [error localizedDescription]);

    [self cancelTransfer:connection];
    [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)data
{
    self.bytesTransfered += data.length;
    if (self.targetFileHandle) {
        [self.targetFileHandle writeData:data];
    } else {
        [self.responseData appendData:data];
    }
}

- (void)updateBytesExpected:(long long)newBytesExpected
{
    DLog(@"Updating bytesExpected to %lld", newBytesExpected);
    self.bytesExpected = newBytesExpected;
}

- (void)connection:(NSURLConnection*)connection didSendBodyData:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{
    NSMutableDictionary* uploadProgress = [NSMutableDictionary dictionaryWithCapacity:3];

    [uploadProgress setObject:[NSNumber numberWithBool:true] forKey:@"lengthComputable"];
    [uploadProgress setObject:[NSNumber numberWithLongLong:totalBytesWritten] forKey:@"loaded"];
    [uploadProgress setObject:[NSNumber numberWithLongLong:totalBytesExpectedToWrite] forKey:@"total"];
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:uploadProgress];
    [result setKeepCallbackAsBool:true];
    [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
    self.bytesTransfered = totalBytesWritten;
}

// for self signed certificates
- (void)connection:(NSURLConnection*)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge*)challenge
{
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        if (self.trustAllHosts) {
            NSURLCredential* credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            [challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
        }
        [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
    } else {
        [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
    }
}

- (id)init
{
    if ((self = [super init])) {
        self.responseData = [NSMutableData data];
        self.targetFileHandle = nil;
    }
    return self;
}

@end;
