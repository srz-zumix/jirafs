// JiraFileSystemURLEnabled.h
// ObjC subclass of JiraFileSystem that statically declares FSServerURLUnaryOperations
// conformance, so fskitd can discover URL-resource support from the binary metadata.
//
// The private FSServerURLUnaryOperations protocol is re-declared here; at runtime
// the ObjC linker merges this declaration with the one in FSKit.framework by name.

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

// ---------------------------------------------------------------------------
// JiraFileSystemURLEnabled — FSServerURLUnaryOperations-aware subclass.
// Returned by JiraFSExtension as the fileSystem instance so fskitd sees static
// FSServerURLUnaryOperations conformance in the binary.
// The five protocol methods are implemented in JiraFileSystem+ServerURL.m as a
// category on JiraFileSystem and are inherited here.
// ---------------------------------------------------------------------------
@interface JiraFileSystemURLEnabled : NSObject
@end

NS_ASSUME_NONNULL_END
