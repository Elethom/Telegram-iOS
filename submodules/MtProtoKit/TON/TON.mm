#import "TON.h"

#import "MTLogging.h"
#import "tonlib/Client.h"
#import "MTQueue.h"
#import "MTSignal.h"

static td::SecureString makeSecureString(NSData * _Nonnull data) {
    if (data == nil || data.length == 0) {
        return td::SecureString();
    } else {
        return td::SecureString((const char *)data.bytes, (size_t)data.length);
    }
}

static std::string makeString(NSData * _Nonnull data) {
    if (data == nil || data.length == 0) {
        return std::string();
    } else {
        return std::string((const char *)data.bytes, ((const char *)data.bytes) + data.length);
    }
}

static NSData * _Nonnull makeData(std::string &string) {
    if (string.size() == 0) {
        return [NSData data];
    } else {
        return [[NSData alloc] initWithBytes:string.data() length:string.size()];
    }
}

static NSString * _Nullable readString(std::string &string) {
    if (string.size() == 0) {
        return @"";
    } else {
        return [[NSString alloc] initWithBytes:string.data() length:string.size() encoding:NSUTF8StringEncoding];
    }
}

static TONTransactionMessage * _Nullable parseTransactionMessage(tonlib_api::object_ptr<tonlib_api::raw_message> &message) {
    if (message == nullptr) {
        return nil;
    }
    NSString *source = readString(message->source_);
    NSString *destination = readString(message->source_);
    if (source == nil || destination == nil) {
        return nil;
    }
    return [[TONTransactionMessage alloc] initWithValue:message->value_ source:source destination:destination];
}

@implementation TONKey

- (instancetype)initWithPublicKey:(NSString *)publicKey secret:(NSData *)secret {
    self = [super init];
    if (self != nil) {
        _publicKey = publicKey;
        _secret = secret;
    }
    return self;
}

@end

@implementation TONAccountState

- (instancetype)initWithBalance:(int64_t)balance seqno:(int32_t)seqno lastTransactionId:(TONTransactionId * _Nullable)lastTransactionId {
    self = [super init];
    if (self != nil) {
        _balance = balance;
        _seqno = seqno;
        _lastTransactionId = lastTransactionId;
    }
    return self;
}

@end

@implementation TONTransactionId

- (instancetype)initWithLt:(int64_t)lt transactionHash:(NSData *)transactionHash {
    self = [super init];
    if (self != nil) {
        _lt = lt;
        _transactionHash = transactionHash;
    }
    return self;
}

@end

@implementation TONTransactionMessage

- (instancetype)initWithValue:(int64_t)value source:(NSString * _Nonnull)source destination:(NSString * _Nonnull)destination {
    self = [super init];
    if (self != nil) {
        _value = value;
        _source = source;
        _destination = destination;
    }
    return self;
}

@end

@implementation TONTransaction

- (instancetype)initWithData:(NSData * _Nonnull)data transactionId:(TONTransactionId * _Nonnull)transactionId timestamp:(int64_t)timestamp fee:(int64_t)fee inMessage:(TONTransactionMessage * _Nullable)inMessage outMessages:(NSArray<TONTransactionMessage *> * _Nonnull)outMessages {
    self = [super init];
    if (self != nil) {
        _data = data;
        _transactionId = transactionId;
        _timestamp = timestamp;
        _fee = fee;
        _inMessage = inMessage;
        _outMessages = outMessages;
    }
    return self;
}

@end

@implementation TONExternalRequest

- (instancetype)initWithData:(NSData * _Nonnull)data onResult:(void (^)(NSData * _Nullable, NSString * _Nullable))onResult {
    self = [super init];
    if (self != nil) {
        _data = data;
        _onResult = [onResult copy];
    }
    return self;
}

@end

using tonlib_api::make_object;

@interface TONReceiveThreadParams : NSObject

@property (nonatomic, readonly) std::shared_ptr<tonlib::Client> client;
@property (nonatomic, copy, readonly) void (^received)(tonlib::Client::Response &);

@end

@implementation TONReceiveThreadParams

- (instancetype)initWithClient:(std::shared_ptr<tonlib::Client>)client received:(void (^)(tonlib::Client::Response &))received {
    self = [super init];
    if (self != nil) {
        _client = client;
        _received = [received copy];
    }
    return self;
}

@end

@interface TONRequestHandler : NSObject

@property (nonatomic, copy, readonly) void (^completion)(tonlib_api::object_ptr<tonlib_api::Object> &);

@end

@implementation TONRequestHandler

- (instancetype)initWithCompletion:(void (^)(tonlib_api::object_ptr<tonlib_api::Object> &))completion {
    self = [super init];
    if (self != nil) {
        _completion = [completion copy];
    }
    return self;
}

@end

@implementation TONError

- (instancetype)initWithText:(NSString *)text {
    self = [super init];
    if (self != nil) {
        _text = text;
    }
    return self;
}

@end

typedef enum {
    TONInitializationStatusInitializing,
    TONInitializationStatusReady,
    TONInitializationStatusError
} TONInitializationStatus;

@interface TON () {
    std::shared_ptr<tonlib::Client> _client;
    uint64_t _nextRequestId;
    NSLock *_requestHandlersLock;
    NSMutableDictionary<NSNumber *, TONRequestHandler *> *_requestHandlers;
    MTPipe *_initializedStatus;
}

@end

@implementation TON

+ (void)receiveThread:(TONReceiveThreadParams *)params {
    while (true) {
        auto response = params.client->receive(1000);
        if (response.object) {
            params.received(response);
        }
    }
}

- (instancetype)initWithKeystoreDirectory:(NSString *)keystoreDirectory config:(NSString *)config performExternalRequest:(void (^)(TONExternalRequest * _Nonnull))performExternalRequest {
    self = [super init];
    if (self != nil) {
        _requestHandlersLock = [[NSLock alloc] init];
        _requestHandlers = [[NSMutableDictionary alloc] init];
        _initializedStatus = [[MTPipe alloc] initWithReplay:true];
        _initializedStatus.sink(@(TONInitializationStatusInitializing));
        _nextRequestId = 1;
        
        _client = std::make_shared<tonlib::Client>();
        
        std::weak_ptr<tonlib::Client> weakClient = _client;
        
        NSLock *requestHandlersLock = _requestHandlersLock;
        NSMutableDictionary *requestHandlers = _requestHandlers;
        NSThread *thread = [[NSThread alloc] initWithTarget:[self class] selector:@selector(receiveThread:) object:[[TONReceiveThreadParams alloc] initWithClient:_client received:^(tonlib::Client::Response &response) {
            if (response.object->get_id() == tonlib_api::updateSendLiteServerQuery::ID) {
                auto result = tonlib_api::move_object_as<tonlib_api::updateSendLiteServerQuery>(response.object);
                int64_t requestId = result->id_;
                NSData *data = makeData(result->data_);
                if (performExternalRequest) {
                    performExternalRequest([[TONExternalRequest alloc] initWithData:data onResult:^(NSData * _Nullable result, NSString * _Nullable error) {
                        auto strongClient = weakClient.lock();
                        if (strongClient != nullptr) {
                            if (result != nil) {
                                auto query = make_object<tonlib_api::onLiteServerQueryResult>(
                                    requestId,
                                    makeString(result)
                                );
                                strongClient->send({ 1, std::move(query) });
                            } else if (error != nil) {
                                auto query = make_object<tonlib_api::onLiteServerQueryError>(
                                    requestId,
                                    make_object<tonlib_api::error>(
                                        400,
                                        error.UTF8String
                                    )
                                );
                                strongClient->send({ 1, std::move(query) });
                            }
                        }
                    }]);
                }
                return;
            }
            NSNumber *requestId = @(response.id);
            [requestHandlersLock lock];
            TONRequestHandler *handler = requestHandlers[requestId];
            [requestHandlers removeObjectForKey:requestId];
            [requestHandlersLock unlock];
            if (handler != nil) {
                handler.completion(response.object);
            }
        }]];
        [thread start];
        
        [[NSFileManager defaultManager] createDirectoryAtPath:keystoreDirectory withIntermediateDirectories:true attributes:nil error:nil];
        
        MTPipe *initializedStatus = _initializedStatus;
        [[self requestInitWithConfigString:config keystoreDirectory:keystoreDirectory] startWithNext:nil error:^(id error) {
            NSString *errorText = @"Unknown error";
            if ([error isKindOfClass:[TONError class]]) {
                errorText = ((TONError *)error).text;
            }
            initializedStatus.sink(@(TONInitializationStatusError));
        } completed:^{
            initializedStatus.sink(@(TONInitializationStatusReady));
        }];
    }
    return self;
}

- (MTSignal *)requestInitWithConfigString:(NSString *)configString keystoreDirectory:(NSString *)keystoreDirectory {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else {
                [subscriber putCompletion];
            }
        }];
        
        auto query = make_object<tonlib_api::init>(make_object<tonlib_api::options>(
            configString.UTF8String,
            keystoreDirectory.UTF8String,
            false
        ));
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)createKeyWithLocalPassword:(NSData *)localPassword mnemonicPassword:(NSData *)mnemonicPassword {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else if (object->get_id() == tonlib_api::key::ID) {
                auto result = tonlib_api::move_object_as<tonlib_api::key>(object);
                NSString *publicKey = [[NSString alloc] initWithData:[[NSData alloc] initWithBytes:result->public_key_.data() length:result->public_key_.length()] encoding:NSUTF8StringEncoding];
                if (publicKey == nil) {
                    [subscriber putError:[[TONError alloc] initWithText:@"Error decoding UTF8 string in createKeyWithLocalPassword"]];
                    return;
                }
                NSData *secret = [[NSData alloc] initWithBytes:result->secret_.data() length:result->secret_.length()];
                [subscriber putNext:[[TONKey alloc] initWithPublicKey:publicKey secret:secret]];
                [subscriber putCompletion];
            } else {
                assert(false);
            }
        }];
        
        auto query = make_object<tonlib_api::createNewKey>(
            makeSecureString(localPassword),
            makeSecureString(mnemonicPassword),
            td::SecureString()
        );
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)getTestWalletAccountAddressWithPublicKey:(NSString *)publicKey {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        NSData *publicKeyData = [publicKey dataUsingEncoding:NSUTF8StringEncoding];
        if (publicKeyData == nil) {
            [subscriber putError:[[TONError alloc] initWithText:@"Error encoding UTF8 string in getTestWalletAccountAddressWithPublicKey"]];
            return [[MTBlockDisposable alloc] initWithBlock:^{}];
        }
        
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else if (object->get_id() == tonlib_api::accountAddress::ID) {
                auto result = tonlib_api::move_object_as<tonlib_api::accountAddress>(object);
                [subscriber putNext:[[NSString alloc] initWithUTF8String:result->account_address_.c_str()]];
                [subscriber putCompletion];
            } else {
                assert(false);
            }
        }];
        
        auto query = make_object<tonlib_api::testWallet_getAccountAddress>(
            make_object<tonlib_api::testWallet_initialAccountState>(
                makeString(publicKeyData)
            )
        );
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)getTestGiverAccountState {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else if (object->get_id() == tonlib_api::testGiver_accountState::ID) {
                auto result = tonlib_api::move_object_as<tonlib_api::testGiver_accountState>(object);
                TONTransactionId *lastTransactionId = [[TONTransactionId alloc] initWithLt:result->last_transaction_id_->lt_ transactionHash:makeData(result->last_transaction_id_->hash_)];
                [subscriber putNext:[[TONAccountState alloc] initWithBalance:result->balance_ seqno:result->seqno_ lastTransactionId:lastTransactionId]];
                [subscriber putCompletion];
            } else {
                assert(false);
            }
        }];
        
        auto query = make_object<tonlib_api::testGiver_getAccountState>();
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)getTestGiverAddress {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else if (object->get_id() == tonlib_api::accountAddress::ID) {
                auto result = tonlib_api::move_object_as<tonlib_api::accountAddress>(object);
                [subscriber putNext:[[NSString alloc] initWithUTF8String:result->account_address_.c_str()]];
                [subscriber putCompletion];
            } else {
                assert(false);
            }
        }];
        
        auto query = make_object<tonlib_api::testGiver_getAccountAddress>();
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)testGiverSendGramsWithAccountState:(TONAccountState *)accountState accountAddress:(NSString *)accountAddress amount:(int64_t)amount {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else {
                [subscriber putCompletion];
            }
        }];
        
        auto query = make_object<tonlib_api::testGiver_sendGrams>(make_object<tonlib_api::accountAddress>(accountAddress.UTF8String), accountState.seqno, amount);
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)getAccountStateWithAddress:(NSString *)accountAddress {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else if (object->get_id() == tonlib_api::generic_accountStateUninited::ID) {
                auto result = tonlib_api::move_object_as<tonlib_api::generic_accountStateUninited>(object);
                [subscriber putNext:[[TONAccountState alloc] initWithBalance:result->account_state_->balance_ seqno:-1 lastTransactionId:nil]];
                [subscriber putCompletion];
            } else if (object->get_id() == tonlib_api::generic_accountStateTestWallet::ID) {
                auto result = tonlib_api::move_object_as<tonlib_api::generic_accountStateTestWallet>(object);
                TONTransactionId *lastTransactionId = [[TONTransactionId alloc] initWithLt:result->account_state_->last_transaction_id_->lt_ transactionHash:makeData(result->account_state_->last_transaction_id_->hash_)];
                [subscriber putNext:[[TONAccountState alloc] initWithBalance:result->account_state_->balance_ seqno:result->account_state_->seqno_ lastTransactionId:lastTransactionId]];
                [subscriber putCompletion];
            } else if (object->get_id() == tonlib_api::generic_accountStateTestGiver::ID) {
                auto result = tonlib_api::move_object_as<tonlib_api::generic_accountStateTestGiver>(object);
                TONTransactionId *lastTransactionId = [[TONTransactionId alloc] initWithLt:result->account_state_->last_transaction_id_->lt_ transactionHash:makeData(result->account_state_->last_transaction_id_->hash_)];
                [subscriber putNext:[[TONAccountState alloc] initWithBalance:result->account_state_->balance_ seqno:result->account_state_->seqno_ lastTransactionId:lastTransactionId]];
                [subscriber putCompletion];
            } else {
                assert(false);
            }
        }];
        
        auto query = make_object<tonlib_api::generic_getAccountState>(make_object<tonlib_api::accountAddress>(accountAddress.UTF8String));
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)sendGramsFromKey:(TONKey *)key localPassword:(NSData *)localPassword fromAddress:(NSString *)fromAddress toAddress:(NSString *)address amount:(int64_t)amount {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        NSData *publicKeyData = [key.publicKey dataUsingEncoding:NSUTF8StringEncoding];
        if (publicKeyData == nil) {
            [subscriber putError:[[TONError alloc] initWithText:@"Error encoding UTF8 string in sendGramsFromKey"]];
            return [[MTBlockDisposable alloc] initWithBlock:^{}];
        }
        
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else {
                [subscriber putCompletion];
            }
        }];
        
        auto query = make_object<tonlib_api::generic_sendGrams>(
            make_object<tonlib_api::inputKey>(
                make_object<tonlib_api::key>(
                    makeString(publicKeyData),
                    makeSecureString(key.secret)
                ),
                makeSecureString(localPassword)
            ),
            make_object<tonlib_api::accountAddress>(fromAddress.UTF8String),
            make_object<tonlib_api::accountAddress>(address.UTF8String),
            amount
        );
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)exportKey:(TONKey *)key localPassword:(NSData *)localPassword {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        NSData *publicKeyData = [key.publicKey dataUsingEncoding:NSUTF8StringEncoding];
        if (publicKeyData == nil) {
            [subscriber putError:[[TONError alloc] initWithText:@"Error encoding UTF8 string in exportKey"]];
            return [[MTBlockDisposable alloc] initWithBlock:^{}];
        }
        
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else if (object->get_id() == tonlib_api::exportedKey::ID) {
                auto result = tonlib_api::move_object_as<tonlib_api::exportedKey>(object);
                NSMutableArray *wordList = [[NSMutableArray alloc] init];
                for (auto &it : result->word_list_) {
                    NSString *string = [[NSString alloc] initWithData:[[NSData alloc] initWithBytes:it.data() length:it.size()] encoding:NSUTF8StringEncoding];
                    if (string == nil) {
                        [subscriber putError:[[TONError alloc] initWithText:@"Error decoding UTF8 string in exportedKey::word_list"]];
                        return;
                    }
                    [wordList addObject:string];
                }
                [subscriber putNext:wordList];
                [subscriber putCompletion];
            } else {
                assert(false);
            }
        }];
        auto query = make_object<tonlib_api::exportKey>(
            make_object<tonlib_api::inputKey>(
                make_object<tonlib_api::key>(
                    makeString(publicKeyData),
                    makeSecureString(key.secret)
                ),
                makeSecureString(localPassword)
            )
        );
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)makeWalletInitialized:(TONKey *)key localPassword:(NSData *)localPassword {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        NSData *publicKeyData = [key.publicKey dataUsingEncoding:NSUTF8StringEncoding];
        if (publicKeyData == nil) {
            [subscriber putError:[[TONError alloc] initWithText:@"Error encoding UTF8 string in exportKey"]];
            return [[MTBlockDisposable alloc] initWithBlock:^{}];
        }
        
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else {
                [subscriber putCompletion];
            }
        }];
        
        auto query = make_object<tonlib_api::testWallet_init>(
            make_object<tonlib_api::inputKey>(
                make_object<tonlib_api::key>(
                    makeString(publicKeyData),
                    makeSecureString(key.secret)
                ),
                makeSecureString(localPassword)
            )
        );
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)importKeyWithLocalPassword:(NSData *)localPassword mnemonicPassword:(NSData *)mnemonicPassword wordList:(NSArray<NSString *> *)wordList {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else if (object->get_id() == tonlib_api::key::ID) {
                auto result = tonlib_api::move_object_as<tonlib_api::key>(object);
                NSString *publicKey = [[NSString alloc] initWithData:[[NSData alloc] initWithBytes:result->public_key_.data() length:result->public_key_.length()] encoding:NSUTF8StringEncoding];
                if (publicKey == nil) {
                    [subscriber putError:[[TONError alloc] initWithText:@"Error decoding UTF8 string in importKeyWithLocalPassword"]];
                    return;
                }
                NSData *secret = [[NSData alloc] initWithBytes:result->secret_.data() length:result->secret_.length()];
                [subscriber putNext:[[TONKey alloc] initWithPublicKey:publicKey secret:secret]];
                [subscriber putCompletion];
            } else {
                assert(false);
            }
        }];
        
        std::vector<td::SecureString> wordVector;
        for (NSString *word in wordList) {
            NSData *wordData = [word dataUsingEncoding:NSUTF8StringEncoding];
            wordVector.push_back(makeSecureString(wordData));
        }
        
        auto query = make_object<tonlib_api::importKey>(
            makeSecureString(localPassword),
            makeSecureString(mnemonicPassword),
            make_object<tonlib_api::exportedKey>(std::move(wordVector)));
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)deleteKeyWithPublicKey:(NSString *)publicKey {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        NSData *publicKeyData = [publicKey dataUsingEncoding:NSUTF8StringEncoding];
        if (publicKeyData == nil) {
            [subscriber putError:[[TONError alloc] initWithText:@"Error encoding UTF8 string in deleteKeyWithPublicKey"]];
            return [[MTBlockDisposable alloc] initWithBlock:^{}];
        }
        
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else {
                [subscriber putCompletion];
            }
        }];
        
        auto query = make_object<tonlib_api::deleteKey>(
            makeString(publicKeyData)
        );
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

- (MTSignal *)getTransactionListWithAddress:(NSString * _Nonnull)address lt:(int64_t)lt hash:(NSData * _Nonnull)hash {
    return [[[[MTSignal alloc] initWithGenerator:^id<MTDisposable>(MTSubscriber *subscriber) {
        NSData *addressData = [address dataUsingEncoding:NSUTF8StringEncoding];
        if (addressData == nil) {
            [subscriber putError:[[TONError alloc] initWithText:@"Error encoding UTF8 string in getTransactionListWithAddress"]];
            return [[MTBlockDisposable alloc] initWithBlock:^{}];
        }
        
        uint64_t requestId = _nextRequestId;
        _nextRequestId += 1;
        
        _requestHandlers[@(requestId)] = [[TONRequestHandler alloc] initWithCompletion:^(tonlib_api::object_ptr<tonlib_api::Object> &object) {
            if (object->get_id() == tonlib_api::error::ID) {
                auto error = tonlib_api::move_object_as<tonlib_api::error>(object);
                [subscriber putError:[[TONError alloc] initWithText:[[NSString alloc] initWithUTF8String:error->message_.c_str()]]];
            } else if (object->get_id() == tonlib_api::raw_transactions::ID) {
                auto result = tonlib_api::move_object_as<tonlib_api::raw_transactions>(object);
                NSMutableArray<TONTransaction *> *transactions = [[NSMutableArray alloc] init];
                for (auto &it : result->transactions_) {
                    TONTransactionId *transactionId = [[TONTransactionId alloc] initWithLt:it->transaction_id_->lt_ transactionHash:makeData(it->transaction_id_->hash_)];
                    TONTransactionMessage *inMessage = parseTransactionMessage(it->in_msg_);
                    NSMutableArray<TONTransactionMessage *> * outMessages = [[NSMutableArray alloc] init];
                    for (auto &messageIt : it->out_msgs_) {
                        TONTransactionMessage *outMessage = parseTransactionMessage(messageIt);
                        if (outMessage != nil) {
                            [outMessages addObject:outMessage];
                        }
                    }
                    [transactions addObject:[[TONTransaction alloc] initWithData:makeData(it->data_) transactionId:transactionId timestamp:it->utime_ fee:it->fee_ inMessage:inMessage outMessages:outMessages]];
                }
                [subscriber putNext:transactions];
                [subscriber putCompletion];
            } else {
                assert(false);
            }
        }];
        
        auto query = make_object<tonlib_api::raw_getTransactions>(
            make_object<tonlib_api::accountAddress>(
                makeString(addressData)
            ),
            make_object<tonlib_api::internal_transactionId>(
                lt,
                makeString(hash)
            )
        );
        _client->send({ requestId, std::move(query) });
        
        return [[MTBlockDisposable alloc] initWithBlock:^{
        }];
    }] startOn:[MTQueue mainQueue]] deliverOn:[MTQueue mainQueue]];
}

@end