// ConfluenceFileSystem+ServerURL.m
// Implements the FSServerURLUnaryOperations informal protocol (private FSKit API).
// This protocol is required for URL-based (confluence://) filesystem mounting via FSClient.

#import <Foundation/Foundation.h>
#import <FSKit/FSKit.h>
#import <objc/runtime.h>

// Private FSKit types — forward declarations only; we interact via id.
@interface FSServerURLParameters : NSObject
@property (nonatomic, copy) NSString *scheme;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *user;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSNumber *port;
@property (nonatomic, copy) NSDictionary *options;
@end

@interface FSServerInfoTask : FSTask
- (void)didCompleteWithServerInfo:(id)info;
@end

@interface FSServerSessionInfoTask : FSTask
- (void)didCompleteWithServerSessionInfo:(id)info;
@end

// Forward-declare the Swift-generated class so ObjC can see it.
@interface ConfluenceFileSystem : FSUnaryFileSystem
@end

@interface ConfluenceFileSystem (ServerURL)

- (id)startOpeningSessionWithTask:(FSTask *)task
                              url:(NSURL *)url
                          options:(NSDictionary *)options
                            error:(NSError **)error;

- (id)startServerInfoFetchWithTask:(FSTask *)task
                               url:(NSURL *)url
                           options:(NSDictionary *)options
                             error:(NSError **)error;

- (void)parseURL:(NSURL *)url
    replyHandler:(void (^)(id parameters, NSError *error))reply;

- (void)composeURL:(id)parameters
      replyHandler:(void (^)(NSURL *url, NSError *error))reply;

- (void)closeSession:(id)session
        replyHandler:(void (^)(NSError *error))reply;

@end

@implementation ConfluenceFileSystem (ServerURL)

- (id)startOpeningSessionWithTask:(FSTask *)task
                              url:(NSURL *)url
                          options:(NSDictionary *)options
                            error:(NSError **)error
{
    Class cls = NSClassFromString(@"FSServerSessionInfoTask");
    FSServerSessionInfoTask *sessionTask = (FSServerSessionInfoTask *)[[cls alloc] init];
    if (sessionTask) {
        [sessionTask didCompleteWithServerSessionInfo:nil];
    }
    return sessionTask;
}

- (id)startServerInfoFetchWithTask:(FSTask *)task
                               url:(NSURL *)url
                           options:(NSDictionary *)options
                             error:(NSError **)error
{
    Class cls = NSClassFromString(@"FSServerInfoTask");
    FSServerInfoTask *infoTask = (FSServerInfoTask *)[[cls alloc] init];
    if (infoTask) {
        [infoTask didCompleteWithServerInfo:nil];
    }
    return infoTask;
}

- (void)parseURL:(NSURL *)url
    replyHandler:(void (^)(id parameters, NSError *error))reply
{
    Class cls = NSClassFromString(@"FSServerURLParameters");
    id params = [[cls alloc] init];
    if (params) {
        [params setValue:url.scheme    forKey:@"scheme"];
        [params setValue:url.host      forKey:@"host"];
        if (url.port) {
            [params setValue:url.port  forKey:@"port"];
        }
        [params setValue:url.path ?: @"" forKey:@"path"];
    }
    reply(params, nil);
}

- (void)composeURL:(id)parameters
      replyHandler:(void (^)(NSURL *url, NSError *error))reply
{
    NSString *scheme = [parameters valueForKey:@"scheme"] ?: @"confluence";
    NSString *host   = [parameters valueForKey:@"host"]   ?: @"";
    NSNumber *port   = [parameters valueForKey:@"port"];
    NSString *path   = [parameters valueForKey:@"path"]   ?: @"";

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = scheme;
    components.host   = host;
    components.port   = port;
    components.path   = path;
    reply(components.URL, nil);
}

- (void)closeSession:(id)session
        replyHandler:(void (^)(NSError *error))reply
{
    reply(nil);
}

@end

// ---------------------------------------------------------------------------
// Register FSServerURLUnaryOperations conformance at load time.
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void registerConfluenceServerURLConformance(void) {
    Protocol *proto = objc_getProtocol("FSServerURLUnaryOperations");
    Class cls = NSClassFromString(@"ConfluenceFileSystem");
    if (proto && cls) {
        class_addProtocol(cls, proto);
    }
}
