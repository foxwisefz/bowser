#import <Foundation/Foundation.h>
#import <xpc/xpc.h>

// Admission probe only. It deliberately implements no subscription service.
static void record(NSString *event, NSDictionary *details) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"event":event, @"details":details}
                                                 options:NSJSONWritingSortedKeys error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL control = argc == 3 && !strcmp(argv[1], "--ping");
        if (!control && argc != 2) return 2;
        const char *name = argv[control ? 2 : 1];
        xpc_connection_t connection = xpc_connection_create_mach_service(
            name, dispatch_get_main_queue(), control ? 0 : XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (control) {
            xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {});
            xpc_connection_activate(connection);
            xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_bool(request, "bowser-probe-control", true);
            xpc_connection_send_message_with_reply(connection, request, dispatch_get_main_queue(), ^(xpc_object_t reply) {
                BOOL ok = xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
                    xpc_dictionary_get_bool(reply, "bowser-probe-control");
                record(@"control_reply", @{@"ok":@(ok)});
                exit(ok ? 0 : 1);
            });
        } else {
            xpc_connection_set_event_handler(connection, ^(xpc_object_t peer) {
                if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
                xpc_connection_set_event_handler(peer, ^(xpc_object_t request) {
                    if (xpc_get_type(request) != XPC_TYPE_DICTIONARY) return;
                    BOOL ping = xpc_dictionary_get_bool(request, "bowser-probe-control");
                    record(ping ? @"control_request" : @"provider_request",
                           @{@"pid":@(xpc_connection_get_pid(peer)),
                             @"protocolVersion":@(xpc_dictionary_get_uint64(request, "protocol version"))});
                    if (ping) {
                        xpc_object_t reply = xpc_dictionary_create_reply(request);
                        if (reply) {
                            xpc_dictionary_set_bool(reply, "bowser-probe-control", true);
                            xpc_connection_send_message(peer, reply);
                        }
                    } else {
                        // Do not imply a subscription exists: this test only checks admission.
                        xpc_connection_cancel(peer);
                    }
                });
                xpc_connection_activate(peer);
            });
            xpc_connection_activate(connection);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (control ? 5 : 60)*NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ exit(control ? 1 : 0); });
        dispatch_main();
    }
}
