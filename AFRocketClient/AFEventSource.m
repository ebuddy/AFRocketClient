// AFEventSource.m
// 
// Copyright (c) 2013 AFNetworking (http://afnetworking.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFEventSource.h"
#import "AFHTTPRequestOperation.h"

typedef void (^AFServerSentEventBlock)(AFServerSentEvent *event);

NSString * const AFEventSourceErrorDomain = @"com.alamofire.networking.event-source.error";

static NSString * const AFEventSourceLockName = @"com.alamofire.networking.event-source.lock";
static NSUInteger const AFEventSourceListenersCapacity = 100;

static NSArray * AFServerSentEventFieldsFromData(NSData *data, NSError * __autoreleasing *error) {
    if (!data || [data length] == 0) {
        return nil;
    }

    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSMutableArray *mutableFieldsArray = [NSMutableArray array];
    
    for (NSString *eventString in [string componentsSeparatedByString:@"\n\n"]) {
        if (![eventString length])
            continue;
        
        NSMutableDictionary *mutableFields = [NSMutableDictionary dictionary];
        for (NSString *line in [eventString componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            // Ignore nil or blank lines, as well as lines beginning with a colon
            if (!line || [line length] == 0 || [line hasPrefix:@":"]) {
                continue;
            }
            
            @autoreleasepool {
                NSScanner *scanner = [[NSScanner alloc] initWithString:line];
                scanner.charactersToBeSkipped = [NSCharacterSet whitespaceCharacterSet];
                NSString *key, *value;
                [scanner scanUpToString:@":" intoString:&key];
                [scanner scanString:@":" intoString:nil];
                [scanner scanUpToString:@"\n" intoString:&value];
                
                if (key && value) {
                    if (mutableFields[key]) {
                        mutableFields[key] = [mutableFields[key] stringByAppendingFormat:@"\n%@", value];
                    } else {
                        mutableFields[key] = value;
                    }
                }
            }
        }
        
        [mutableFieldsArray addObject:mutableFields];
    }
    
    return mutableFieldsArray;
}

@implementation AFServerSentEvent

+ (instancetype)eventWithFields:(NSDictionary *)fields {
    if (!fields.count) {
        return nil;
    }

    AFServerSentEvent *event = [[self alloc] init];

    NSMutableDictionary *mutableFields = [NSMutableDictionary dictionaryWithDictionary:fields];
    event.event = mutableFields[@"event"];
    event.identifier = mutableFields[@"id"];
    event.data = [mutableFields[@"data"] dataUsingEncoding:NSUTF8StringEncoding];
    event.retry = [mutableFields[@"retry"] integerValue];

    [mutableFields removeObjectsForKeys:@[@"event", @"id", @"data", @"retry"]];
    event.userInfo = mutableFields;

    return event;
}

+ (NSArray*)eventsWithFields:(NSArray *)fieldsArray {
    if (!fieldsArray) {
        return nil;
    }
    
    NSMutableArray *events = [NSMutableArray array];
    for (NSDictionary *fields in fieldsArray) {
        AFServerSentEvent* event = [self eventWithFields:fields];
        if(event){
            [events addObject:event];
        }
    }
    
    return events;
}

#pragma mark - NSCoding

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [self init];
    if (!self) {
        return nil;
    }

    self.event = [aDecoder decodeObjectForKey:@"event"];
    self.identifier = [aDecoder decodeObjectForKey:@"identifier"];
    self.data = [aDecoder decodeObjectForKey:@"data"];
    self.retry = [aDecoder decodeIntegerForKey:@"retry"];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.event forKey:@"event"];
    [aCoder encodeObject:self.identifier forKey:@"identifier"];
    [aCoder encodeObject:self.data forKey:@"data"];
    [aCoder encodeInteger:self.retry forKey:@"retry"];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    AFServerSentEvent *event = [[[self class] allocWithZone:zone] init];
    event.event = self.event;
    event.identifier = self.identifier;
    event.data = self.data;
    event.retry = self.retry;

    return event;
}

@end

#pragma mark -

typedef NS_ENUM(NSUInteger, AFEventSourceState) {
    AFEventSourceConnecting = 0,
    AFEventSourceOpen = 1,
    AFEventSourceClosed = 2,
};

NSTimeInterval const kAFEventSourceDefaultRetryInterval = 10.0;

@interface AFEventSource () <NSStreamDelegate>
@property (readwrite, nonatomic, strong) AFHTTPRequestOperation *requestOperation;
@property (readwrite, nonatomic, assign) AFEventSourceState state;
@property (readwrite, nonatomic, strong) NSURLRequest *request;
@property (readwrite, nonatomic, strong) NSHTTPURLResponse *lastResponse;
@property (readwrite, nonatomic, strong) AFServerSentEvent *lastEvent;
@property (readwrite, nonatomic, strong) NSMapTable *listenersKeyedByEvent;
@property (readwrite, nonatomic, strong) NSOutputStream *outputStream;
@property (readwrite, nonatomic, assign) NSUInteger offset;
@property (readwrite, nonatomic, strong) NSRecursiveLock *lock;
@end

@implementation AFEventSource

- (instancetype)initWithURL:(NSURL *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];

    return [self initWithRequest:request];
}

- (instancetype)initWithRequest:(NSURLRequest *)request {
    self = [super init];
    if (!self) {
        return nil;
    }

    self.request = request;

    self.listenersKeyedByEvent = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsCopyIn valueOptions:NSPointerFunctionsStrongMemory capacity:AFEventSourceListenersCapacity];

    self.lock = [[NSRecursiveLock alloc] init];
    self.lock.name = AFEventSourceLockName;

    NSError *error = nil;
    [self open:&error];
    if (error) {
        if ([self.delegate respondsToSelector:@selector(eventSource:didFailWithError:)]) {
            [self.delegate eventSource:self didFailWithError:error];
        }
    }

    self.retryInterval = kAFEventSourceDefaultRetryInterval;
    return self;
}

- (BOOL)isConnecting {
    return self.state == AFEventSourceConnecting;
}

- (BOOL)isOpen {
    return self.state == AFEventSourceOpen;
}

- (BOOL)isClosed {
    return self.state == AFEventSourceClosed;
}

- (NSHTTPURLResponse *)lastResponse {
    return self.requestOperation.response;
}

- (NSData *)receivedData {
    return [self.requestOperation.outputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
}

- (BOOL)open:(NSError * __autoreleasing *)error {
    if ([self isOpen]) {
        if (error) {
            *error = [NSError errorWithDomain:AFEventSourceErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedStringFromTable(@"Event Source Already Opened", @"AFEventSource", nil) }];
        }

        return NO;
    }

    [self.lock lock];
    self.state = AFEventSourceConnecting;
    self.offset = 0;

    self.requestOperation = [[AFHTTPRequestOperation alloc] initWithRequest:self.request];
    self.requestOperation.responseSerializer = [AFServerSentEventResponseSerializer serializer];
    self.outputStream = [NSOutputStream outputStreamToMemory];
    self.outputStream.delegate = self;
    self.requestOperation.outputStream = self.outputStream;

    [self.requestOperation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {

        [self didCloseSuccessfully];
        [self reconnectAfterRetryInterval];
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {

        [self didCloseWithError:error];
        [self reconnectAfterRetryInterval];
    }];
    
    [self.requestOperation start];
    [self.lock unlock];

    return YES;
}

- (BOOL)close:(NSError * __autoreleasing *)error {
    if ([self isClosed]) {
        if (error) {
            *error = [NSError errorWithDomain:AFEventSourceErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: NSLocalizedStringFromTable(@"Event Source Already Closed", @"AFEventSource", nil) }];
        }

        return NO;
    }

    [self.requestOperation cancel];
    return YES;
}

#pragma mark -

- (NSUInteger)addListenerForEvent:(NSString *)event
                       usingBlock:(void (^)(AFServerSentEvent *event))block
{
    NSMutableDictionary *mutableListenersKeyedByIdentifier = [self.listenersKeyedByEvent objectForKey:event];
    if (!mutableListenersKeyedByIdentifier) {
        mutableListenersKeyedByIdentifier = [NSMutableDictionary dictionary];
    }

    NSUInteger identifier = [[NSUUID UUID] hash];
    mutableListenersKeyedByIdentifier[@(identifier)] = [block copy];
    
    [self.listenersKeyedByEvent setObject:mutableListenersKeyedByIdentifier forKey:event];

    return identifier;
}

- (void)removeEventListenerWithIdentifier:(NSUInteger)identifier {
    NSEnumerator *enumerator = [self.listenersKeyedByEvent keyEnumerator];
    id event = nil;
    while ((event = [enumerator nextObject])) {
        NSMutableDictionary *mutableListenersKeyedByIdentifier = [self.listenersKeyedByEvent objectForKey:event];
        if ([mutableListenersKeyedByIdentifier objectForKey:@(identifier)]) {
            [mutableListenersKeyedByIdentifier removeObjectForKey:@(identifier)];
            [self.listenersKeyedByEvent setObject:mutableListenersKeyedByIdentifier forKey:event];
            return;
        }
    }
}

- (void)removeAllListenersForEvent:(NSString *)event {
    [self.listenersKeyedByEvent removeObjectForKey:event];
}

#pragma mark - Private

- (void)reconnectAfterRetryInterval {
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.retryInterval * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        if(![self isOpen]){
            [self open:nil];
        }
    });
}

#pragma mark - Events

- (void)didOpen {
    if (![self isOpen]) {
        [self.lock lock];
        self.state = AFEventSourceOpen;
        self.offset = 0;
        if ([self.delegate respondsToSelector:@selector(eventSourceDidOpen:)]) {
            [self.delegate eventSourceDidOpen:self];
        }
        [self.lock unlock];
    }
}

- (void)didCloseWithError:(NSError *)error {
    if (![self isClosed]) {
        [self.lock lock];
        self.state = AFEventSourceClosed;
        self.offset = 0;
        if (error.code == NSURLErrorCancelled) {
            if ([self.delegate respondsToSelector:@selector(eventSourceDidClose:)]) {
                [self.delegate eventSourceDidClose:self];
            }
        } else {
            if ([self.delegate respondsToSelector:@selector(eventSource:didFailWithError:)]) {
                [self.delegate eventSource:self didFailWithError:error];
            }
        }

        //Reset State
        [self.outputStream close];
        self.outputStream.delegate = nil;
        self.outputStream = nil;
        self.requestOperation= nil;

        [self.lock unlock];
    }
}

- (void)didCloseSuccessfully {
    if (![self isClosed]) {
        [self.lock lock];
        self.state = AFEventSourceClosed;
        self.offset = 0;
        if ([self.delegate respondsToSelector:@selector(eventSourceDidClose:)]) {
            [self.delegate eventSourceDidClose:self];
        }

        //Reset State
        [self.outputStream close];
        self.outputStream.delegate = nil;
        self.outputStream = nil;
        self.requestOperation= nil;

        [self.lock unlock];
    }
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode {
    switch (eventCode) {

        case NSStreamEventOpenCompleted: {
            [self didOpen];
            break;
        }

        case NSStreamEventHasSpaceAvailable: {
            NSData *data = [stream propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
            NSError *error = nil;
            NSArray *events = [[AFServerSentEventResponseSerializer serializer] responseObjectForResponse:self.lastResponse data:[data subdataWithRange:NSMakeRange(self.offset, [data length] - self.offset)] error:&error];
            self.offset = [data length];

            if (error) {
                if ([self.delegate respondsToSelector:@selector(eventSource:didFailWithError:)]) {
                    [self.delegate eventSource:self didFailWithError:error];
                }
            } else {
                if (events.count) {
                    if ([self.delegate respondsToSelector:@selector(eventSource:didReceiveMessage:)]) {
                        for (AFServerSentEvent *event in events)
                            [self.delegate eventSource:self didReceiveMessage:event];
                    }
                    for (AFServerSentEvent* event in events) {
                        if(event.retry>0){
                            //We divide by zero here as the value is in milliseconds according to spec but NSTimeInterval is in seconds.
                            self.retryInterval = event.retry/1000;
                        }
                        [[self.listenersKeyedByEvent objectForKey:event.event] enumerateKeysAndObjectsUsingBlock:^(id key, AFServerSentEventBlock block, BOOL *stop) {
                            if (block) {
                                block(event);
                            }
                        }];
                    }
                }
            }
            break;
        }
        default:
            break;
    }
}

#pragma mark - NSCoding

- (id)initWithCoder:(NSCoder *)aDecoder {
    NSURLRequest *request = [aDecoder decodeObjectForKey:@"request"];

    self = [self initWithRequest:request];
    if (!self) {
        return nil;
    }

    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:self.request forKey:@"request"];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    return [[[self class] allocWithZone:zone] initWithRequest:self.request];
}

@end

#pragma mark -

@implementation AFServerSentEventResponseSerializer

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    self.acceptableContentTypes = [[NSSet alloc] initWithObjects:@"text/event-stream", nil];

    return self;
}

#pragma mark - AFURLResponseSerializer

- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        return nil;
    }

    
    return [AFServerSentEvent eventsWithFields:AFServerSentEventFieldsFromData(data, error)];
}

@end
