//
//  main.m
//  libdispatch f'ery
//
// Different tests will be enabled depending on the preprocessor TEST number
// For example, to compile TEST1, execute the following:
// clang main.m -o /tmp/dispatch_test -DTEST1

#pragma mark - headers start -

#import <Foundation/Foundation.h>
#import <sys/queue.h> // LIST_ENTRY
#include <malloc/malloc.h>
#include <os/lock.h> // mega pthread struct
#include <pthread/sched.h> // mega pthread struct

#import <mach-o/getsect.h>
#import <mach-o/ldsyms.h>
#include <objc/runtime.h>
#include <mach-o/dyld_images.h>
#include <mach/task.h>
#include <dlfcn.h>
#include <pthread/pthread.h>
#include <sys/event.h> // kevent stuff

extern const struct dispatch_queue_offsets_s {
    // always add new fields at the end
    const uint16_t dqo_version;
    const uint16_t dqo_label;
    const uint16_t dqo_label_size;
    const uint16_t dqo_flags;
    const uint16_t dqo_flags_size;
    const uint16_t dqo_serialnum;
    const uint16_t dqo_serialnum_size;
    const uint16_t dqo_width;
    const uint16_t dqo_width_size;
    const uint16_t dqo_running;
    const uint16_t dqo_running_size;
    // fields added in dqo_version 5:
    const uint16_t dqo_suspend_cnt;
    const uint16_t dqo_suspend_cnt_size;
    const uint16_t dqo_target_queue;
    const uint16_t dqo_target_queue_size;
    const uint16_t dqo_priority;
    const uint16_t dqo_priority_size;
} dispatch_queue_offsets;

extern const struct dispatch_tsd_indexes_s {
    // always add new fields at the end
    const uint16_t dti_version;
    const uint16_t dti_queue_index;
    const uint16_t dti_voucher_index;
    const uint16_t dti_qos_class_index;
    /* version 3 */
    const uint16_t dti_continuation_cache_index;
} dispatch_tsd_indexes;



extern const struct dispatch_allocator_layout_s {
    const uint16_t dal_version;
    /* version 1 */
    /* Pointer to the allocator metadata address, points to NULL if unused */
    void **const dal_allocator_zone;
    /* Magical "isa" for allocations that are on freelists */
    void *const *const dal_deferred_free_isa;
    /* Size of allocations made in the magazine */
    const uint16_t dal_allocation_size;
    /* fields used by the enumerator */
    const uint16_t dal_magazine_size;
    const uint16_t dal_first_allocation_offset;
    const uint16_t dal_allocation_isa_offset;
    /* Enumerates allocated continuations */
    kern_return_t (*dal_enumerator)(task_t remote_task,
            const struct dispatch_allocator_layout_s *remote_allocator_layout,
            vm_address_t zone_address, memory_reader_t reader,
            void (^recorder)(vm_address_t dc_address, void *dc_mem,
                    size_t size, bool *stop));
} dispatch_allocator_layout;


typedef unsigned long pthread_priority_t;
struct voucher_hash_entry_s {
    uintptr_t vhe_next;
    uintptr_t vhe_prev_ptr;
};
typedef uint64_t firehose_activity_id_t;
struct voucher_s {
    struct voucher_vtable_s *os_obj_isa;
    volatile int os_obj_ref_cnt;
    volatile int os_obj_xref_cnt;
    struct voucher_hash_entry_s v_list;
    mach_voucher_t v_kvoucher;
    mach_voucher_t v_ipc_kvoucher;
    struct voucher_s* v_kvbase;
    firehose_activity_id_t v_activity;
    uint64_t v_activity_creator;
    firehose_activity_id_t v_parent_activity;
    unsigned int v_kv_has_importance : 1;
};

struct dispatch_continuation_s {
    union {
        const void *do_vtable;
        uintptr_t dc_flags;
    };
    union {
        pthread_priority_t dc_priority;
        int dc_cache_cnt;
        uintptr_t dc_pad;
    };
    struct dispatch_continuation_s *volatile do_next;
    struct voucher_s *dc_voucher;
    dispatch_function_t dc_func;
    void *dc_ctxt;
    void *dc_data;
    void *dc_other;
};

struct dispatch_object_s;
struct dispatch_invoke_context_s {
    uint64_t dic_next_narrow_check;
    struct dispatch_object_s *dic_barrier_waiter;
    uint32_t dic_barrier_waiter_bucket;
    void *dic_autorelease_pool;
};


DISPATCH_OPTIONS(dispatch_invoke_flags, uint32_t,
    DISPATCH_INVOKE_NONE                    = 0x00000000,

    // Invoke modes
    //
    // @const DISPATCH_INVOKE_STEALING
    // This invoke is a stealer, meaning that it doesn't own the
    // enqueue lock at drain lock time.
    //
    // @const DISPATCH_INVOKE_WLH
    // This invoke is for a bottom WLH
    //
    DISPATCH_INVOKE_STEALING                = 0x00000001,
    DISPATCH_INVOKE_WLH                        = 0x00000002,

    // Misc flags
    //
    // @const DISPATCH_INVOKE_ASYNC_REPLY
    // An asynchronous reply to a message is being handled.
    //
    // @const DISPATCH_INVOKE_DISALLOW_SYNC_WAITERS
    // The next serial drain should not allow sync waiters.
    //
    DISPATCH_INVOKE_ASYNC_REPLY                = 0x00000004,
    DISPATCH_INVOKE_DISALLOW_SYNC_WAITERS    = 0x00000008,

    // Below this point flags are propagated to recursive calls to drain(),
    // continuation pop() or dx_invoke().
#define _DISPATCH_INVOKE_PROPAGATE_MASK          0xffff0000u

    // Drain modes
    //
    // @const DISPATCH_INVOKE_WORKER_DRAIN
    // Invoke has been issued by a worker thread (work queue thread, or
    // pthread root queue) drain. This flag is NOT set when the main queue,
    // manager queue or runloop queues are drained
    //
    // @const DISPATCH_INVOKE_REDIRECTING_DRAIN
    // Has only been draining concurrent queues so far
    // Implies DISPATCH_INVOKE_WORKER_DRAIN
    //
    // @const DISPATCH_INVOKE_MANAGER_DRAIN
    // We're draining from a manager context
    //
    // @const DISPATCH_INVOKE_THREAD_BOUND
    // We're draining from the context of a thread-bound queue (main thread)
    //
    // @const DISPATCH_INVOKE_WORKLOOP_DRAIN
    // The queue at the bottom of this drain is a workloop that supports
    // reordering.
    //
    // @const DISPATCH_INVOKE_COOPERATIVE_DRAIN
    // The queue at the bottom of this drain is a cooperative global queue
    //
    DISPATCH_INVOKE_WORKER_DRAIN            = 0x00010000,
    DISPATCH_INVOKE_REDIRECTING_DRAIN        = 0x00020000,
    DISPATCH_INVOKE_MANAGER_DRAIN            = 0x00040000,
    DISPATCH_INVOKE_THREAD_BOUND            = 0x00080000,
    DISPATCH_INVOKE_WORKLOOP_DRAIN            = 0x00100000,
    DISPATCH_INVOKE_COOPERATIVE_DRAIN        = 0x00200000,
#define _DISPATCH_INVOKE_DRAIN_MODE_MASK      0x00ff0000u

    // Autoreleasing modes
    //
    // @const DISPATCH_INVOKE_AUTORELEASE_ALWAYS
    // Always use autoreleasepools around callouts
    //
    // @const DISPATCH_INVOKE_AUTORELEASE_NEVER
    // Never use autoreleasepools around callouts
    //
    DISPATCH_INVOKE_AUTORELEASE_ALWAYS        = 0x01000000,
    DISPATCH_INVOKE_AUTORELEASE_NEVER        = 0x02000000,
#define _DISPATCH_INVOKE_AUTORELEASE_MASK      0x03000000u

    // @const DISPATCH_INVOKE_DISABLED_NARROWING
    // Don't check for narrowing during this invoke
    DISPATCH_INVOKE_DISABLED_NARROWING        = 0x4000000,
);

struct dispatch_object_extra_vtable_s {
    const unsigned long do_type;
    void (*const do_dispose)(struct dispatch_object_s *, bool *);
    size_t (*const do_debug)(struct dispatch_object_s *, char *, size_t);
    void (*const do_invoke)(struct dispatch_object_s *, struct dispatch_invoke_context_s*, dispatch_invoke_flags_t);
};

struct dispatch_object_vtable_s {
    void *_os_obj_objc_class_t[5];
    struct dispatch_object_extra_vtable_s _os_obj_vtable;
};

struct dispatch_object_s {
    const struct dispatch_object_vtable_s *do_vtable;
    volatile int do_ref_cnt;
    volatile int do_xref_cnt;
    struct dispatch_object_s *volatile do_next;
    struct dispatch_queue_s *do_targetq;
    void *do_ctxt;
    union {
        dispatch_function_t do_finalizer;
        void *do_introspection_ctxt;
    };
};
typedef uint32_t dispatch_priority_t;
typedef uint32_t dispatch_lock;

struct dispatch_queue_s {
    struct dispatch_object_s _as_do[0];
    struct dispatch_object_s _as_os_obj[0];
    void *do_vtable; // const dispatch_queue_vtable_s
    volatile int do_ref_cnt;
    volatile int do_xref_cnt;
    struct dispatch_queue_s *volatile do_next;
    struct dispatch_queue_s *do_targetq;
    void *do_ctxt;
    union {
        dispatch_function_t do_finalizer;
        void *do_introspection_ctxt;
    };
    void *__dq_opaque1;
    union {
        volatile uint64_t dq_state;
        struct {
            dispatch_lock dq_state_lock;
            uint32_t dq_state_bits;
        };
    };
    unsigned long dq_serialnum;
    const char *dq_label;
    union {
        volatile uint32_t dq_atomic_flags;
        struct {
            const uint16_t dq_width;
            const uint16_t __dq_opaque2;
        };
    };
    dispatch_priority_t dq_priority;
    union {
        struct dispatch_queue_specific_head_s *dq_specific_head;
        struct dispatch_source_refs_s *ds_refs;
        struct dispatch_timer_source_refs_s *ds_timer_refs;
        struct dispatch_mach_recv_refs_s *dm_recv_refs;
        const struct dispatch_channel_callbacks_s *dch_callbacks;
    };
    volatile int dq_sref_cnt;
};

typedef uint32_t dispatch_lock;
typedef struct dispatch_unfair_lock_s {
    dispatch_lock dul_lock;
} dispatch_unfair_lock_s;
struct dispatch_lane_s {
    struct dispatch_queue_s _as_dq[0];
    struct dispatch_object_s _as_do[0];
    void *do_vtable;
    volatile int do_ref_cnt;
    volatile int do_xref_cnt;
    struct dispatch_lane_s *volatile do_next;
    struct dispatch_queue_s *do_targetq;
    void *do_ctxt;
    union {
        dispatch_function_t do_finalizer;
        void *do_introspection_ctxt;
    };
    struct dispatch_object_s *volatile dq_items_tail;
    union {
        volatile uint64_t dq_state;
        struct {
            dispatch_lock dq_state_lock;
            uint32_t dq_state_bits;
        };
    };
    unsigned long dq_serialnum;
    const char *dq_label;
    union {
        volatile uint32_t dq_atomic_flags;
        struct {
            const uint16_t dq_width;
            const uint16_t __dq_opaque2;
        };
    };
    dispatch_priority_t dq_priority;
    union {
        struct dispatch_queue_specific_head_s *dq_specific_head;
        struct dispatch_source_refs_s *ds_refs;
        struct dispatch_timer_source_refs_s *ds_timer_refs;
        struct dispatch_mach_recv_refs_s *dm_recv_refs;
        const struct dispatch_channel_callbacks_s *dch_callbacks;
    };
    volatile int dq_sref_cnt;
    dispatch_unfair_lock_s dq_sidelock;
    struct dispatch_object_s *volatile dq_items_head;
    uint32_t dq_side_suspend_cnt;
};

// a lane is pretty much a dispatch_queue_static used by the main queue and a few others
#define dispatch_queue_static_s dispatch_lane_s

struct dispatch_queue_specific_head_s {
    dispatch_unfair_lock_s dqsh_lock;
    struct {
        struct dispatch_queue_specific_s *tqh_first;
        struct dispatch_queue_specific_s **tqh_last;
    };
    TAILQ_HEAD(, dispatch_queue_specific_s) dqsh_entries;
};

struct dispatch_introspection_thread_s {
    void *dit_isa;
    LIST_ENTRY(dispatch_introspection_thread_s) dit_list;
    pthread_t thread;
    struct dispatch_queue_s **queue;
};

typedef union dispatch_thread_frame_s *dispatch_thread_frame_t;
union dispatch_thread_frame_s {
    struct {
        dispatch_queue_t dtf_queue;
        dispatch_thread_frame_t dtf_prev;
    };
    void *dtf_pair[2];
};

struct dispatch_queue_global_s {
    struct dispatch_queue_s _as_dq[0];
    struct dispatch_object_s _as_do[0];
    const struct dispatch_lane_vtable_s *do_vtable;
    volatile int do_ref_cnt;
    volatile int do_xref_cnt;
    struct dispatch_lane_s *volatile do_next;
    struct dispatch_queue_s *do_targetq;
    void *do_ctxt;
    union {
        dispatch_function_t do_finalizer;
        void *do_introspection_ctxt;
    };
    struct dispatch_object_s *volatile dq_items_tail;
    union {
        volatile uint64_t dq_state;
        struct {
            dispatch_lock dq_state_lock;
            uint32_t dq_state_bits;
        };
    };
    unsigned long dq_serialnum;
    const char *dq_label;
    union {
        volatile uint32_t dq_atomic_flags;
        struct {
            const uint16_t dq_width;
            const uint16_t __dq_opaque2;
        };
    };
    dispatch_priority_t dq_priority;
    union {
        struct dispatch_queue_specific_head_s *dq_specific_head;
        struct dispatch_source_refs_s *ds_refs;
        struct dispatch_timer_source_refs_s *ds_timer_refs;
        struct dispatch_mach_recv_refs_s *dm_recv_refs;
        const struct dispatch_channel_callbacks_s *dch_callbacks;
    };
    volatile int dq_sref_cnt;
    volatile int dgq_thread_pool_size;
    struct dispatch_object_s *volatile dq_items_head;
    volatile int dgq_pending;
};

DISPATCH_ENUM(dispatch_mach_msg_destructor, unsigned int,
    DISPATCH_MACH_MSG_DESTRUCTOR_DEFAULT = 0,
    DISPATCH_MACH_MSG_DESTRUCTOR_FREE,
    DISPATCH_MACH_MSG_DESTRUCTOR_VM_DEALLOCATE,
);


struct dispatch_mach_msg_s {
    struct dispatch_object_s _as_do[0];
    const struct dispatch_mach_msg_vtable_s *do_vtable;
    volatile int do_ref_cnt;
    volatile int do_xref_cnt;
    struct dispatch_mach_msg_s *volatile do_next;
    struct dispatch_queue_s *do_targetq;
    void *do_ctxt;
    union {
        dispatch_function_t do_finalizer;
        void *do_introspection_ctxt;
    };
    union {
        mach_msg_option_t dmsg_options;
        mach_error_t dmsg_error;
    };
    mach_port_t dmsg_reply;
    pthread_priority_t dmsg_priority;
    struct voucher_s* dmsg_voucher;
    dispatch_mach_msg_destructor_t dmsg_destructor;
    size_t dmsg_size;
    union {
        mach_msg_header_t *dmsg_msg;
        char dmsg_buf[0];
    };
};

typedef uintptr_t dispatch_unote_state_t;
typedef uint32_t dispatch_unote_ident_t;

DISPATCH_ENUM(dispatch_mach_reason, unsigned long,
    DISPATCH_MACH_CONNECTED = 1,
    DISPATCH_MACH_MESSAGE_RECEIVED,
    DISPATCH_MACH_MESSAGE_SENT,
    DISPATCH_MACH_MESSAGE_SEND_FAILED,
    DISPATCH_MACH_MESSAGE_NOT_SENT,
    DISPATCH_MACH_BARRIER_COMPLETED,
    DISPATCH_MACH_DISCONNECTED,
    DISPATCH_MACH_CANCELED,
    DISPATCH_MACH_REPLY_RECEIVED,
    DISPATCH_MACH_NEEDS_DEFERRED_SEND,
    DISPATCH_MACH_SIGTERM_RECEIVED,
    DISPATCH_MACH_ASYNC_WAITER_DISCONNECTED,
    DISPATCH_MACH_NO_SENDERS,
    DISPATCH_MACH_REASON_LAST, /* unused */
);

typedef struct dispatch_mach_msg_s* dispatch_mach_msg_t;
typedef void (*dispatch_mach_handler_function_t)(void *_Nullable context,
        dispatch_mach_reason_t reason, dispatch_mach_msg_t _Nullable message,
        mach_error_t error);

struct dispatch_mach_send_refs_s {
    dispatch_source_type_t du_type;
    uintptr_t du_owner_wref;
    volatile dispatch_unote_state_t du_state;
    dispatch_unote_ident_t du_ident;
    int8_t du_filter;
    uint8_t du_is_direct : 1;
    uint8_t du_is_timer : 1;
    uint8_t du_has_extended_status : 1;
    uint8_t du_memorypressure_override : 1;
    uint8_t du_vmpressure_override : 1;
    uint8_t du_can_be_wlh : 1;
    uint8_t dmrr_handler_is_block : 1;
    uint8_t du_unused_flag : 1;
    union {
        uint8_t du_timer_flags;
        volatile bool dmsr_notification_armed;
        bool dmr_reply_port_owned;
    };
    uint8_t du_unused;
    uint32_t du_fflags;
    unsigned long du_priority;
    struct dispatch_unfair_lock_s dmsr_replies_lock;
    struct dispatch_mach_msg_s dmsr_checkin;
    
    struct dispatch_mach_reply_refs_s *lh_first;
    LIST_HEAD(, dispatch_mach_reply_refs_s) dmsr_replies;
    union {
        volatile uint64_t dmsr_state;
        struct {
            dispatch_unfair_lock_s dmsr_state_lock;
            uint32_t dmsr_state_bits;
        };
    };
    struct dispatch_object_s *volatile dmsr_tail;
    struct dispatch_object_s *volatile dmsr_head;
    volatile uint32_t dmsr_disconnect_cnt;
    mach_port_t dmsr_send;
    mach_port_t dmsr_checkin_port;
};

typedef struct dispatch_mach_send_refs_s* dispatch_mach_send_refs_t;

struct dispatch_mach_s {
    const struct dispatch_mach_msg_vtable_s *do_vtable;
    volatile int do_ref_cnt;
    volatile int do_xref_cnt;
    struct dispatch_mach_s *volatile do_next;
    struct dispatch_queue_s *do_targetq;
    void *do_ctxt;
    union {
        dispatch_function_t do_finalizer;
        void *do_introspection_ctxt;
    };
    struct dispatch_object_s *volatile dq_items_tail;
    union {
        volatile uint64_t dq_state;
        struct {
            dispatch_lock dq_state_lock;
            uint32_t dq_state_bits;
        };
    };
    unsigned long dq_serialnum;
    const char *dq_label;
    union {
        volatile uint32_t dq_atomic_flags;
        struct {
            const uint16_t dq_width;
            const uint16_t __dq_opaque2;
        };
    };
    dispatch_priority_t dq_priority;
    union {
        struct dispatch_queue_specific_head_s *dq_specific_head;
        struct dispatch_source_refs_s *ds_refs;
        struct dispatch_timer_source_refs_s *ds_timer_refs;
        struct dispatch_mach_recv_refs_s *dm_recv_refs;
        const struct  dispatch_channel_callbacks_s *dch_callbacks;
    };
    volatile int dq_sref_cnt;
    struct dispatch_unfair_lock_s dq_sidelock;
    struct dispatch_object_s *volatile dq_items_head;
    uint32_t dq_side_suspend_cnt;
    uint16_t ds_is_installed : 1;
    uint16_t ds_latched : 1;
    uint16_t dm_connect_handler_called : 1;
    uint16_t dm_cancel_handler_called : 1;
    uint16_t dm_is_xpc : 1;
    uint16_t dm_arm_no_senders : 1;
    uint16_t dm_made_sendrights : 1;
    uint16_t dm_strict_reply : 1;
    uint16_t __ds_flags_pad : 8;
//    uint16_t __dq_flags_separation[];
    uint16_t dm_needs_mgr : 1;
    uint16_t dm_disconnected : 1;
    uint16_t __dm_flags_pad : 14;
    struct dispatch_mach_send_refs_s* dm_send_refs;
    struct dispatch_xpc_term_refs_s* dm_xpc_term_refs;
};

struct dispatch_mach_recv_refs_s {
    dispatch_source_type_t du_type;
    uintptr_t du_owner_wref;
    volatile dispatch_unote_state_t du_state;
    dispatch_unote_ident_t du_ident;
    int8_t du_filter;
    uint8_t du_is_direct : 1;
    uint8_t du_is_timer : 1;
    uint8_t du_has_extended_status : 1;
    uint8_t du_memorypressure_override : 1;
    uint8_t du_vmpressure_override : 1;
    uint8_t du_can_be_wlh : 1;
    uint8_t dmrr_handler_is_block : 1;
    uint8_t du_unused_flag : 1;
    union {
        uint8_t du_timer_flags;
        volatile bool dmsr_notification_armed;
        bool dmr_reply_port_owned;
    };
    uint8_t du_unused;
    uint32_t du_fflags;
    dispatch_priority_t du_priority;
    dispatch_mach_handler_function_t dmrr_handler_func;
    void *dmrr_handler_ctxt;
};

struct dispatch_source_refs_s {
    dispatch_source_type_t du_type;
    uintptr_t du_owner_wref;
    volatile dispatch_unote_state_t du_state;
    dispatch_unote_ident_t du_ident;
    int8_t du_filter;
    uint8_t du_is_direct : 1;
    uint8_t du_is_timer : 1;
    uint8_t du_has_extended_status : 1;
    uint8_t du_memorypressure_override : 1;
    uint8_t du_vmpressure_override : 1;
    uint8_t du_can_be_wlh : 1;
    uint8_t dmrr_handler_is_block : 1;
    uint8_t du_unused_flag : 1;
    union {
        uint8_t du_timer_flags;
        volatile bool dmsr_notification_armed;
        bool dmr_reply_port_owned;
    };
    uint8_t du_unused;
    uint32_t du_fflags;
    dispatch_priority_t du_priority;
    struct dispatch_continuation_s *volatile ds_handler[3];
    uint64_t ds_data;
    uint64_t ds_pending_data;
};

struct dispatch_timer_source_s {
    union {
        struct {
            uint64_t target;
            uint64_t deadline;
        };
        uint64_t heap_key[2];
    };
    uint64_t interval;
};

struct dispatch_timer_source_refs_s {
    dispatch_source_type_t du_type;
    uintptr_t du_owner_wref;
    volatile dispatch_unote_state_t du_state;
    dispatch_unote_ident_t du_ident;
    int8_t du_filter;
    uint8_t du_is_direct : 1;
    uint8_t du_is_timer : 1;
    uint8_t du_has_extended_status : 1;
    uint8_t du_memorypressure_override : 1;
    uint8_t du_vmpressure_override : 1;
    uint8_t du_can_be_wlh : 1;
    uint8_t dmrr_handler_is_block : 1;
    uint8_t du_unused_flag : 1;
    union {
        uint8_t du_timer_flags;
        volatile bool dmsr_notification_armed;
        bool dmr_reply_port_owned;
    };
    uint8_t du_unused;
    uint32_t du_fflags;
    dispatch_priority_t du_priority;
    struct dispatch_continuation_s *volatile ds_handler[3];
    uint64_t ds_data;
    uint64_t ds_pending_data;
    struct dispatch_timer_source_s dt_timer;
    struct dispatch_timer_config_s *dt_pending_config;
    uint32_t dt_heap_entry[2];
};

typedef os_unfair_lock _pthread_lock;
typedef struct internal_pthread_layout_s {
    long sig;
    struct __darwin_pthread_handler_rec *__cleanup_stack;

    //
    // Fields protected by _pthread_list_lock
    //

    TAILQ_ENTRY(pthread_s) tl_plist;              // global thread list [aligned]
    struct pthread_join_context_s *tl_join_ctx;
    void *tl_exit_value;
    uint8_t tl_policy;
    // pthread knows that tl_joinable bit comes immediately after tl_policy
    uint8_t
        tl_joinable:1,
        tl_joiner_cleans_up:1,
        tl_has_custom_stack:1,
        __tl_pad:5;
    uint16_t introspection;
    // MACH_PORT_NULL if no joiner
    // tsd[_PTHREAD_TSD_SLOT_MACH_THREAD_SELF] when has a joiner
    // MACH_PORT_DEAD if the thread exited
    uint32_t tl_exit_gate;
    struct sched_param tl_param;
    void *__unused_padding;

    //
    // Fields protected by pthread_t::lock
    //

    _pthread_lock lock;
    uint16_t max_tsd_key;
    uint16_t
        inherit:8,
        kernalloc:1,
        schedset:1,
        wqthread:1,
        wqkillset:1,
        __flags_pad:4;

    char pthread_name[MAXTHREADNAMESIZE];   // includes NUL [aligned]

    void  *(*fun)(void *);  // thread start routine
    void    *arg;           // thread start routine argument
    int      wq_nevents;    // wqthreads (workloop / kevent)
    bool     wq_outsideqos;
    uint8_t  canceled;      // 4597450 set if conformant cancelation happened
    uint16_t cancel_state;  // whether the thread can be canceled [atomic]
    errno_t  cancel_error;
    errno_t  err_no;        // thread-local errno

    void    *stackaddr;     // base of the stack (page aligned)
    void    *stackbottom;   // stackaddr - stacksize
    void    *freeaddr;      // stack/thread allocation base address
    size_t   freesize;      // stack/thread allocation size
    size_t   guardsize;     // guard page size in bytes

    // tsd-base relative accessed elements
    __attribute__((aligned(8)))
    uint64_t thread_id;     // 64-bit unique thread id

    /* Thread Specific Data slots
     *
     * The offset of this field from the start of the structure is difficult to
     * change on OS X because of a thorny bitcompat issue: mono has hard coded
     * the value into their source.  Newer versions of mono will fall back to
     * scanning to determine it at runtime, but there's lots of software built
     * with older mono that won't.  We will have to break them someday...
     */
    __attribute__ ((aligned (16)))
    void* __PTHREAD_TSD_SLOT_PTHREAD_SELF;   //              __TSD_THREAD_SELF
    void* __PTHREAD_TSD_SLOT_ERRNO;                //     __TSD_ERRNO
    void* __PTHREAD_TSD_SLOT_MIG_REPLY;              //   __TSD_MIG_REPLY
    void* __PTHREAD_TSD_SLOT_MACH_THREAD_SELF;         // __TSD_MACH_THREAD_SELF
    void* __PTHREAD_TSD_SLOT_PTHREAD_QOS_CLASS;         //__TSD_THREAD_QOS_CLASS
    void* __PTHREAD_TSD_SLOT_RETURN_TO_KERNEL;          //__TSD_RETURN_TO_KERNEL
    void * unused_slot_6;
    void* __PTHREAD_TSD_SLOT_PTR_MUNGE;                 //__TSD_PTR_MUNGE
    void* __PTHREAD_TSD_SLOT_MACH_SPECIAL_REPLY;        //__TSD_MACH_SPECIAL_REPLY
    void* __PTHREAD_TSD_SLOT_SEMAPHORE_CACHE ;          //__TSD_SEMAPHORE_CACHE
    
    void* libc_locale_key   ;   //  10
    void* __WINDOWS_ptk_libc_reserved_win64 ;  // 11
    void* libc_localtime_key;  //  12
    void* libc_gmtime_key ;    //   13
    void* libc_gdtoa_bigint_key ; //  14
    void* libc_parsefloat_key ; //  15
    void* libc_ttyname_key  ;   //   16
    
    void * __unused_slot_17; // 17
    ///* for usage by dyld */
    void* DYLD_Unwind_SjLj_Key;//    18
    
    void * __unused19; // 19
    
    struct dispatch_queue_s* dispatch_queue_key; //        = __PTK_LIBDISPATCH_KEY0;
    dispatch_thread_frame_t dispatch_frame_key; //        = __PTK_LIBDISPATCH_KEY1;
    struct dispatch_continuation_s* dispatch_cache_key; //        = __PTK_LIBDISPATCH_KEY2;
    void* dispatch_context_key; //        = __PTK_LIBDISPATCH_KEY3;
    void* dispatch_pthread_root_queue_observer_hooks_key; // =;
    void* dispatch_basepri_key; //     = __PTK_LIBDISPATCH_KEY5;
    struct dispatch_introspection_thread_s* dispatch_introspection_or_bcounter_key; // = __PTK_LIBDISPATCH_KEY6;
    void* dispatch_wlh_key; //            = __PTK_LIBDISPATCH_KEY7;
    void* dispatch_voucher_key; //        = OS_VOUCHER_TSD_KEY;
    void* dispatch_deferred_items_key; // = __PTK_LIBDISPATCH_KEY9;
    
    void* dispatch_quantum_key; // = __PTK_LIBDISPATCH_KEY10;
    void* dispatch_dsc_key; // = __PTK_LIBDISPATCH_KEY11;
    void* dispatch_enqueue_key; // = __PTK_LIBDISPATCH_KEY12; // 29
    
    /* Keys 30-39 for Graphic frameworks usage */
    void * _PTHREAD_TSD_SLOT_OPENGL; //    30    /* backwards compat sake */
    void * __PTK_FRAMEWORK_OPENGL_KEY; //    30
    void * __PTK_FRAMEWORK_GRAPHICS_KEY1; //    31
    void * __PTK_FRAMEWORK_GRAPHICS_KEY2; //    32
    void * __PTK_FRAMEWORK_GRAPHICS_KEY3; //    33
    void * __PTK_FRAMEWORK_GRAPHICS_KEY4; //    34
    void * __PTK_FRAMEWORK_GRAPHICS_KEY5; //    35
    void * __PTK_FRAMEWORK_GRAPHICS_KEY6; //    36
    void * __PTK_FRAMEWORK_GRAPHICS_KEY7; //    37
    void * __PTK_FRAMEWORK_GRAPHICS_KEY8; //    38
    void * __PTK_FRAMEWORK_GRAPHICS_KEY9; //    39

    /* Keys 40-49 for Objective-C runtime usage */
    void* __PTK_FRAMEWORK_OBJC_KEY0; //    40
    void* __PTK_FRAMEWORK_OBJC_KEY1; //    41
    void* __PTK_FRAMEWORK_OBJC_KEY2; //    42
    void* __PTK_FRAMEWORK_OBJC_KEY3; //    43
    void* __PTK_FRAMEWORK_OBJC_KEY4; //    44
    void* __PTK_FRAMEWORK_OBJC_KEY5; //    45
    void* __PTK_FRAMEWORK_OBJC_KEY6; //    46
    void* __PTK_FRAMEWORK_OBJC_KEY7; //    47
    void* __PTK_FRAMEWORK_OBJC_KEY8; //    48
    void* __PTK_FRAMEWORK_OBJC_KEY9; //    49

    void* __PTK_FRAMEWORK_COREFOUNDATION_KEY0; //    50
    void* __PTK_FRAMEWORK_COREFOUNDATION_KEY1; //    51
    void* __PTK_FRAMEWORK_COREFOUNDATION_KEY2; //    52
    void* __PTK_FRAMEWORK_COREFOUNDATION_KEY3; //    53
    void* __PTK_FRAMEWORK_COREFOUNDATION_KEY4; //    54
    void* __PTK_FRAMEWORK_COREFOUNDATION_KEY5; //    55
    void* __PTK_FRAMEWORK_COREFOUNDATION_KEY6; //    56
    void* __PTK_FRAMEWORK_COREFOUNDATION_KEY7; //    57
    void* __PTK_FRAMEWORK_COREFOUNDATION_KEY8; //    58
    void* __PTK_FRAMEWORK_COREFOUNDATION_KEY9; //    59
    void* __PTK_FRAMEWORK_FOUNDATION_KEY0; //        60
    void* __PTK_FRAMEWORK_FOUNDATION_KEY1; //        61
    void* __PTK_FRAMEWORK_FOUNDATION_KEY2; //        62
    void* __PTK_FRAMEWORK_FOUNDATION_KEY3; //        63
    void* __PTK_FRAMEWORK_FOUNDATION_KEY4; //        64
    void* __PTK_FRAMEWORK_FOUNDATION_KEY5; //        65
    void* __PTK_FRAMEWORK_FOUNDATION_KEY6; //        66
    void* __PTK_FRAMEWORK_FOUNDATION_KEY7; //        67
    void* __PTK_FRAMEWORK_FOUNDATION_KEY8; //        68
    void* __PTK_FRAMEWORK_FOUNDATION_KEY9; //        69
    void* __PTK_FRAMEWORK_QUARTZCORE_KEY0; //        70
    void* __PTK_FRAMEWORK_QUARTZCORE_KEY1; //        71
    void* __PTK_FRAMEWORK_QUARTZCORE_KEY2; //        72
    void* __PTK_FRAMEWORK_QUARTZCORE_KEY3; //        73
    void* __PTK_FRAMEWORK_QUARTZCORE_KEY4; //        74
    void* __PTK_FRAMEWORK_QUARTZCORE_KEY5; //        75
    void* __PTK_FRAMEWORK_QUARTZCORE_KEY6; //        76
    void* __PTK_FRAMEWORK_QUARTZCORE_KEY7; //        77
    void* __PTK_FRAMEWORK_QUARTZCORE_KEY8; //        78
    void* __PTK_FRAMEWORK_QUARTZCORE_KEY9; //        79
    void* __PTK_FRAMEWORK_COREDATA_KEY0; //        80
    void* __PTK_FRAMEWORK_COREDATA_KEY1; //        81
    void* __PTK_FRAMEWORK_COREDATA_KEY2; //        82
    void* __PTK_FRAMEWORK_COREDATA_KEY3; //        83
    void* __PTK_FRAMEWORK_COREDATA_KEY4; //        84
    void* __PTK_FRAMEWORK_COREDATA_KEY5; //        85
    void* __PTK_FRAMEWORK_COREDATA_KEY6; //        86
    void* __PTK_FRAMEWORK_COREDATA_KEY7; //        87
    void* __PTK_FRAMEWORK_COREDATA_KEY8; //        88
    void* __PTK_FRAMEWORK_COREDATA_KEY9; //        89
    void* __PTK_FRAMEWORK_JAVASCRIPTCORE_KEY0; //        90
    void* __PTK_FRAMEWORK_JAVASCRIPTCORE_KEY1; //        91
    void* __PTK_FRAMEWORK_JAVASCRIPTCORE_KEY2; //        92
    void* __PTK_FRAMEWORK_JAVASCRIPTCORE_KEY3; //        93
    void* __PTK_FRAMEWORK_JAVASCRIPTCORE_KEY4; //        94
    void* __PTK_FRAMEWORK_CORETEXT_KEY0; //            95
    void* __PTK_FRAMEWORK_SWIFT_KEY0; //        100
    void* __PTK_FRAMEWORK_SWIFT_KEY1; //        101
    void* __PTK_FRAMEWORK_SWIFT_KEY2; //        102
    void* __PTK_FRAMEWORK_SWIFT_KEY3; //        103
    void* __PTK_FRAMEWORK_SWIFT_KEY4; //        104
    void* __PTK_FRAMEWORK_SWIFT_KEY5; //        105
    void* __PTK_FRAMEWORK_SWIFT_KEY6; //        106
    void* __PTK_FRAMEWORK_SWIFT_KEY7; //        107
    void* __PTK_FRAMEWORK_SWIFT_KEY8; //        108
    void* __PTK_FRAMEWORK_SWIFT_KEY9; //        109
    void* __PTK_LIBMALLOC_KEY0; //        110
    void* __PTK_LIBMALLOC_KEY1; //        111
    void* __PTK_LIBMALLOC_KEY2; //        112
    void* __PTK_LIBMALLOC_KEY3; //        113
    void* __PTK_LIBMALLOC_KEY4; //        114
    
    void *os_workgroup_key; // 115
    void *__PTK_LIBDISPATCH_WORKGROUP_KEY1;
    void *__PTK_LIBDISPATCH_WORKGROUP_KEY2;
    void *__PTK_LIBDISPATCH_WORKGROUP_KEY3;
    void *__PTK_LIBDISPATCH_WORKGROUP_KEY4;
    
    void *dispatch_upper_1;
    void *dispatch_upper_2;
    void *dispatch_upper_3;
    void *dispatch_msgv_aux_key;
    void *dispatch_upper_5;
  
} my_pthread_t;


#pragma mark - headers end -


#if defined(TEST1) // Tests adding work to a dispatch queue without executing any functions

void do_stuff(void* context) {
    printf("woot %p\n", context);
}

int main(int argc, const char* argv[]) {
    struct dispatch_lane_s *q =
                 (__bridge struct dispatch_lane_s *)(dispatch_get_main_queue());
    
    struct dispatch_continuation_s cs = {
        .dc_func = do_stuff,
        .dc_ctxt = (void*)0x1234567,
    };
    
    q->dq_items_head = (void*)&cs;
    q->dq_items_tail = (void*)&cs;
    q->dq_state |= 0x0000008000000000ull;
    
    dispatch_main();
    
    return 0;
}

#elif defined(TEST2) // Tests enumerating blocks in an executable


bool ptr_is_block_class(uintptr_t ptr) {
    uintptr_t block_classes[] = {
        (uintptr_t)objc_getClass("__NSStackBlock__"),
        (uintptr_t)objc_getClass("__NSMallocBlock__"),
        (uintptr_t)objc_getClass("__NSAutoBlock__"),
        (uintptr_t)objc_getClass("__NSFinalizingBlock__"),
        (uintptr_t)objc_getClass("__NSGlobalBlock__"),
        (uintptr_t)objc_getClass("__NSBlockVariable__"),
    };
    // ~7 needed because isa's can pack bits AND have ptrauth
    uintptr_t resolved = (uintptr_t)ptrauth_strip((void*)ptr, ptrauth_key_objc_isa_pointer) & ~7LL;
    for (int i = 0; i < sizeof(block_classes)/sizeof(void*); i++) {
        if (resolved == block_classes[i]) {
            return true;
        }
    }
    return false;
}

int main(int argc, const char * argv[]) {
    task_dyld_info_data_t tdi;
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    assert(task_info(mach_task_self(), TASK_DYLD_INFO, (void*)&tdi, &cnt) == KERN_SUCCESS);
    
    struct dyld_all_image_infos *all_image_infos = (void*)tdi.all_image_info_addr;
    struct dyld_image_info *infos = (void*)all_image_infos->infoArray;

    // Iterate every image
    for (uint i = 0; i < all_image_infos->infoArrayCount; i++) {
        
        unsigned long size = 0;
        char *segments_with_blocks[] = { "__DATA_CONST", "__AUTH_CONST" }; // blocks in __DATA_CONST.__const or __AUTH_CONST.__const
        
        for (uint j = 0; j < 2; j++) {
            uintptr_t *payload = (void*)getsectiondata((void*)infos[i].imageLoadAddress, segments_with_blocks[j], "__const", &size);
            if (!payload) {
                continue;
            }
            
            for (uint k = 0; k < (size/sizeof(uintptr_t)); k++) {
                if (ptr_is_block_class(payload[k])) {
                    printf("Potential block at: %p", &payload[k]);
                    struct {
                        void *isa; int flags; int reserved; void* fptr; struct block_descriptor *descriptor;
                    } *potential_block = (void*)&payload[k];
                    
                    Dl_info dlifno;
                    if (dladdr(potential_block->fptr, &dlifno)) {
                        printf(" %s 0x%016lx %s",  dlifno.dli_fname, (uintptr_t)potential_block->fptr, dlifno.dli_sname);
                    }
                    putchar('\n');
                }
            }
        }
    }
    return 0;
}

#elif defined(TEST3) // Shows the TSD offsets and the libdispatch exported struct offsets


typedef struct pthread_join_context_s {
    pthread_t   waiter;
    void      **value_ptr;
    mach_port_t kport;
    semaphore_t custom_stack_sema;
    bool        detached;
} pthread_join_context_s, *pthread_join_context_t;

#define MAXTHREADNAMESIZE               64


#pragma mark - ex2 -
int main(void) {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        /*  pthread_self equivalent to the following on arm64
            pthread_t p;
            __asm__ ("mrs %0, TPIDRRO_EL0" : "=r" (p));
         */
        __unused my_pthread_t *dispatch_thread = (void*)pthread_self();
        

//        __unused typeof(dispatch_tsd_indexes) *tsd  = &dispatch_tsd_indexes;
//        struct dispatch_queue_s *queue = pthread_getspecific(tsd->dti_queue_index);
//        
//        assert(queue == dispatch_thread->dispatch_queue_key);
        
        printf("");
        
    });

    __unused my_pthread_t *thread = (void*)pthread_self();
        
    dispatch_main();
    return 0;
}

#elif defined(TEST4) // block interposing

static void(*og_function)(id) = NULL; // If a block had params, they'd go after the id block
void interposed_function(id block) {
    if (og_function) {
        og_function(block);
    }
}

int main(int argc, const char* argv[]) {
    /*
     <__NSGlobalBlock__: 0x1e67420f8>
      signature: "v8@?0", invoke : 0x2b4400018efe4354 (/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation`__25+[NSBundle allFrameworks]_block_invoke)
     */
    struct Block_layout {
        void *isa; // objc instance for ARC
        volatile int32_t flags; // contains ref count
        int32_t reservered;
        void* invoke;
        struct Block_descriptor *descriptor;
    } *b = (void*)0x1e67420f8;
    
    assert(vm_protect(mach_task_self(), 0x1e67420f8, sizeof(struct Block_layout), false,
                      VM_PROT_READ|VM_PROT_WRITE) == KERN_SUCCESS);
    
    og_function = ptrauth_strip(b->invoke, ptrauth_key_block_function);
    og_function = ptrauth_sign_unauthenticated(og_function, ptrauth_key_process_independent_code, 0);
    
    void* stripped_interposed = ptrauth_strip((void*)interposed_function, ptrauth_key_block_function);
    b->invoke = ptrauth_sign_unauthenticated(stripped_interposed, ptrauth_key_block_function, &b->invoke);
    
    [NSBundle allFrameworks];
    
    return 0;
}

#elif defined(TEST5) // libdispatch uses kevents, this showcases a kevent example


typedef uint64_t kqueue_id_t;
struct kevent_qos_s {
    uint64_t        ident;          /* identifier for this event */
    int16_t         filter;         /* filter for event */
    uint16_t        flags;          /* general flags */
    int32_t         qos;            /* quality of service */
    uint64_t        udata;          /* opaque user data identifier */
    uint32_t        fflags;         /* filter-specific flags */
    uint32_t        xflags;         /* extra filter-specific flags */
    int64_t         data;           /* filter-specific data */
    uint64_t        ext[4];         /* filter-specific extensions */
};
int kevent_qos(int kq,
    const struct kevent_qos_s *changelist, int nchanges,
    struct kevent_qos_s *eventlist, int nevents,
    void *data_out, size_t *data_available,
    unsigned int flags);

int kevent_id(kqueue_id_t id,
    const struct kevent_qos_s *changelist, int nchanges,
    struct kevent_qos_s *eventlist, int nevents,
    void *data_out, size_t *data_available,
    unsigned int flags);

/*
 EVFILT_MACHPORT  Takes the name of a mach port, or port set, in ident and waits until a message is enqueued on the port or port set. When a message is detected, but not directly received by the kevent call, the name of the specific port where the message is enqueued is returned in data.  If fflags contains MACH_RCV_MSG, the ext[0] and ext[1] flags are assumed to contain a pointer to the buffer where the message is to be received and the size of the receive buffer, respectively. If MACH_RCV_MSG is specifed, yet the buffer size in ext[1] is zero, The space for the buffer may be carved out of the data_out area provided to kevent_qos() if there is enough space remaining there.
 */

int main(int argc, const char* argv[]) {
    
    // generate a port
    mach_port_options_t opts = { .flags = MPO_INSERT_SEND_RIGHT };
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr =  mach_port_construct(mach_task_self(), &opts, 0, &port);
    
    // generate the kqueue
    int kq = kqueue();
    
    // add port to listen for port receives
    struct kevent64_s event = {
        .ident  = port,
        .filter = EVFILT_MACHPORT,
        .flags  = EV_ADD|EV_ENABLE,
        .udata  = 0x420420420420,
        .fflags = MACH_RCV_MSG,
    };
    assert(kevent64(kq, &event, 1, 0, 0, 0, NULL) != -1);
    
    
    const mach_msg_id_t msgid = 0x12345;
    mach_msg_header_t header = {
        .msgh_remote_port = port,
        .msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, 0),
        .msgh_id = msgid,
    };
    
    // send a mach msg
    kr = mach_msg(&header, MACH_SEND_MSG, sizeof(header), 0, 0, 0, 0);
    
    mach_msg_empty_rcv_t recv = {};
    struct kevent_qos_s e = { .fflags = MACH_RCV_MSG };
    size_t sz = sizeof(recv);
    assert(kevent_qos(kq, NULL, 0, &e, 1, &recv, &sz, 0) == 1); // amount of in msgs
    
    assert(e.ident == port);
    assert(recv.header.msgh_id == msgid);
    
    __builtin_dump_struct(&e, &printf);
    __builtin_dump_struct(&recv, &printf);
    
    typedef uint64_t kqueue_id_t;
    int proc_list_dynkqueueids(int pid, kqueue_id_t *buf, uint32_t bufsz);
    int proc_piddynkqueueinfo(int pid, int flavor, kqueue_id_t kq_id, void *buffer,
        int buffersize);
    
    extern int proc_list_uptrs(pid_t pid, uint64_t *buffer, uint32_t buffersize);
    uint64_t ptrs[20];
    int cnt = proc_list_uptrs(getpid(), ptrs, sizeof(ptrs));
    assert(cnt == 1); // only one event has been created for kevent monitoring
    assert(ptrs[0] == 0x420420420420);
    
    // remove from first kq
    event.flags = EV_DELETE;
    assert(kevent64(kq, &event, 1, 0, 0, 0, NULL) != -1);
    
    //  now try the kevent_id with a dispatch queue
    dispatch_queue_t queue = dispatch_queue_create("some.queue", DISPATCH_QUEUE_CONCURRENT);
    event.flags =  EV_ADD|EV_ENABLE;
    sz = sizeof(recv);
    kevent_id(queue, &event, 1, NULL, 0, &recv, &sz, 0);
    return 0;
}


#elif defined(TEST6) // list the blocks waiting to be executed on the main dispatch queue

/* From queue_internal.h
 
 // skip zero
 // 1 - main_q
 // 2 - mgr_q
 // 3 - mgr_root_q
 // 4 - 21 - global queues
 // 22 - workloop_fallback_q
 // we use 'xadd' on Intel, so the initial value == next assigned
 #define DISPATCH_QUEUE_SERIAL_NUMBER_INIT 22
 extern unsigned long volatile _dispatch_queue_serial_numbers;

 // mark the workloop fallback queue to avoid finalizing objects on the base
 // queue of custom outside-of-qos workloops
 #define DISPATCH_QUEUE_SERIAL_NUMBER_WLF 22

 extern struct dispatch_queue_static_s _dispatch_mgr_q; // serial 2
 #if DISPATCH_USE_MGR_THREAD && DISPATCH_USE_PTHREAD_ROOT_QUEUES
 extern struct dispatch_queue_global_s _dispatch_mgr_root_queue; // serial 3
 #endif
 extern struct dispatch_queue_global_s _dispatch_root_queues[]; // serials 4 - 21
 */

void do_stuff(void* context) {
    printf("woot %p\n", context);
}

int main(int argc, const char* argv[]) {
    struct dispatch_lane_s *q =
                 (__bridge struct dispatch_lane_s *)(dispatch_get_main_queue());
    
    struct dispatch_continuation_s cs = {
        .dc_func = do_stuff,
        .dc_ctxt = (void*)0x1234567,
    };
    
    q->dq_items_head = (void*)&cs;
    q->dq_items_tail = (void*)&cs;
    q->dq_state |= 0x0000008000000000ull;
    
    dispatch_main();
    
    return 0;
}
#elif defined(TEST7) // tests dispatch sources along with pthread offsets

int main(int argc, const char* argv[]) {
    mach_port_options_t opts = {
        .flags = MPO_INSERT_SEND_RIGHT,
    };
    
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr =  mach_port_construct(mach_task_self(), &opts, 0, &port);
    
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, port, 0, dispatch_get_main_queue());
    
    dispatch_source_set_event_handler(source, ^{
        __unused my_pthread_t *dispatch_thread = (void*)pthread_self();
        __builtin_dump_struct(dispatch_thread, &printf);
        // inspect this pthread_stuff
        __builtin_debugtrap();
    });
    
    dispatch_resume(source);
    
    mach_msg_header_t header = {
        .msgh_remote_port = port,
        .msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, 0),
    };
    
    kr = mach_msg(&header, MACH_SEND_MSG, sizeof(header), 0, 0, 0, 0);
 
    dispatch_main();
}
#elif defined(TEST8) // tests dispatch sources along with pthread offsets
#include <notify.h>

typedef struct {
    void *isa; // initialized an objc block cls
    int flags;
    int reserved;
    void* invoke;
    struct block_descriptor *descriptor;
    // imported variables here, i.e. context's 0x123456789
} Block_literal;

static void(*og_function)(id, int) = NULL; // If a block had params, they'd go after the id block
void interposed_function(id block, int cnt) {
    if (og_function) {
        og_function(block, cnt);
    }
}


void some_repeating_timer(void(^callback)(int)) {
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    dispatch_async(queue, ^{
        int count = 0;
        sleep(2);
        callback(count);
    });
}

void malloc_ptr_enumerator(task_t task, void *context, unsigned type,
                           vm_range_t *ranges, unsigned count) {
    
    for (uint i = 0; i < count; i++) {
        uintptr_t *potential_block = (void*)ranges[i].address;
        size_t sz = ranges[i].size;
        
        if (sz < sizeof(Block_literal)) {
            continue;
        }
        
        // see if the isa matches
        void* stripped_isa = ptrauth_strip((void*)potential_block[0], ptrauth_key_objc_isa_pointer);
        if (stripped_isa != context) {
            continue;
        }
        
        // do interposing on this instance of the block
        malloc_printf("found address at %p\n", potential_block);
    }
    
}

int main(int argc, const char* argv[]) {

    malloc_zone_t *zone = malloc_default_zone();
    zone->introspect->force_lock(zone);
    zone->introspect->enumerator(mach_task_self(), (__bridge void*)objc_getClass("__NSMallocBlock__"),
                                 MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)zone, NULL, malloc_ptr_enumerator);
    zone->introspect->force_unlock(zone);
    
    dispatch_main();
}

#else
#pragma mark - ex1 -
#import <Foundation/Foundation.h>

int main(void) {
    
    typedef struct {
        unsigned long int reserved;     // NULL
        unsigned long int size;         // sizeof(struct Block_literal_1)
        const char *signature;                         // IFF (1<<30) 0x40000000
    } block_descriptor;

    typedef struct {
        void *isa; // initialized an objc block cls
        int flags;
        int reserved;
        void* fptr;
        block_descriptor *descriptor;
        // imported variables here, i.e. context's 0x123456789
    } Block_literal;
    
    void *context = (void*)0x123456789;
    
    void (^Some_Block)(NSString*, uintptr_t, uintptr_t) = ^(NSString *arg1, uintptr_t arg2, uintptr_t arg3) {
        NSLog(@"arg1: %@, arg2: %lx, arg3: %lx, context: %p", arg1, arg2, arg3, context);
    };
    
    
    __unused Block_literal *b = (__bridge void*)Some_Block;
    
    Some_Block(@"HI", 1, 2);
    
    return 0;
}

#endif

// search for blocks in an arm64e executable
// lipo -thin arm64e /usr/libexec/logd -o /tmp/logd
// P=/tmp/logd
// dyld_info -fixups $P | grep const| grep Block  | grep 6AE1  | awk '{print $3}' | while read x; do echo "block: $x"; read -r a b<<<  $(xxd -g 4 -e -l 16 -s $((($x & 0xFFFFFFFF)+ 0x10 )) $P | awk '{print $2 " 0x" $4}'  )  ; if nm $P | grep -q $a; then nm $P | grep $a; fi; strings -a -t x $P | grep -i  $(xxd -g 4 -e -l 4 -s $(($b + 16)) $P | awk '{print $2}' | sed 's/^0*//'  )   ; done
