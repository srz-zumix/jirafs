// JiraFileSystemURLEnabled.h
// Re-declares the private FSServerURLUnaryOperations protocol so that other
// translation units can reference it by type.  The actual protocol conformance
// is registered dynamically in JiraFileSystem+ServerURL.m via class_addProtocol,
// which runs at load time through __attribute__((constructor)).
//
// There is no JiraFileSystemURLEnabled subclass: JiraFileSystem itself is used
// directly, and fskitd discovers URL-resource support via conformsToProtocol:.

#import <Foundation/Foundation.h>
#import <FSKit/FSKit.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// FSServerURLUnaryOperations — private FSKit protocol (re-declared by name).
// fskitd checks for this conformance before allowing FSServerURLResource mounts.
// ---------------------------------------------------------------------------
@protocol FSServerURLUnaryOperations <NSObject>

@required

/// Initiate a server session for the given URL.
- (nullable id)startOpeningSessionWithTask:(FSTask *)task
                                       url:(NSURL *)url
                                   options:(nullable NSDictionary *)options
                                     error:(NSError * _Nullable * _Nullable)outError;

/// Fetch server metadata for the given URL.
- (nullable id)startServerInfoFetchWithTask:(FSTask *)task
                                        url:(NSURL *)url
                                    options:(nullable NSDictionary *)options
                                      error:(NSError * _Nullable * _Nullable)outError;

/// Decompose a URL into FSServerURLParameters.
- (void)parseURL:(NSURL *)url
    replyHandler:(void (^)(id _Nullable parameters,
                           NSError * _Nullable error))replyHandler;

/// Reassemble a URL from FSServerURLParameters.
- (void)composeURL:(id)parameters
      replyHandler:(void (^)(NSURL * _Nullable url,
                             NSError * _Nullable error))replyHandler;

/// Close a server session.
- (void)closeSession:(nullable id)session
        replyHandler:(void (^)(NSError * _Nullable error))replyHandler;

@end

NS_ASSUME_NONNULL_END
