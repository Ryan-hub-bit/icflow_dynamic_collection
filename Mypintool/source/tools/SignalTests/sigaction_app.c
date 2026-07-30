/*
 * Copyright (C) 2024-2024 Intel Corporation.
 * SPDX-License-Identifier: MIT
 */

/*! @file
 * This application uses 'sigaction' functionality as followed -
 *
 * 1. application create 10 threads
 *
 * 2. Each thread perform in loop (10000 times) the following -
 *   2.1 sets 'segfault_handler()' function as handler for SIGSEGV using sigaction system call
 *   2.2 generates deliberate segfault error
 *   2.3 segfault caught by the sa_sigaction handler we set before
 *   2.4 RIP is being set to (next) address stored in advance in RDX, allowing graceful continuation of the thread.
 *
 * 3. All threads finished
 *
 * The application also checks errors when using 'sigaction' by trying to set handler to SIGSTOP and SIGKILL (which is not allowed).
 *
 * The purpose of this test application is to check that calling 'sigaction' from multiple thread
 * does not interfere with each other, when registering on the same signal and running under Pin.
 *
 */

#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <assert.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h> /* Definition of SYS_* constants */

#define __USE_GNU
#include <ucontext.h>

#define DEBUG(...)                            \
    do                                        \
    {                                         \
        assert(td != NULL);                   \
        fprintf(stdout, "[tid=%d]", td->tid); \
        fprintf(stdout, __VA_ARGS__);         \
        fflush(stdout);                       \
    }                                         \
    while (0);

#define REG_RDX 12
#define REG_RIP 16

void segfault_handler(int sig, siginfo_t* si, void* ucontext)
{
    ucontext_t* const uc = (ucontext_t*)ucontext;
    if (sig == SIGSEGV)
    {
        uc->uc_mcontext.gregs[REG_RIP] = uc->uc_mcontext.gregs[REG_RDX];
    }
}

typedef struct _thread_data
{
    int tid;
} thread_data;

void* set_sigaction(void* data)
{
    thread_data* td = (thread_data*)data;
    DEBUG("Entering thread.\n");

    int i = 0;
    for (i = 0; i < 10000; ++i)
    {
        // prepare 'segfault_handler' function as handler for SIGSEGV
        struct sigaction act;
        memset(&act, 0, sizeof(act));
        act.sa_sigaction = segfault_handler;
        act.sa_flags     = SA_SIGINFO;
        sigemptyset(&act.sa_mask);
        sigaction(SIGSEGV, &act, NULL);

        asm volatile("movq $0x0, %rax      \n\t"
                     "leaq 0x0(%rip), %rdx \n\t" // Store RIP
                     "addq $0xc, %rdx      \n\t" // Update RIP to last asm instruction below
                     "movq $1, (%rax)      \n\t" // Generate segfault
                     "movq $0x10, %rax     \n\t");
    }
    DEBUG("Exiting thread.\n");
    return td;
}

int main()
{
    struct sigaction act;
    memset(&act, 0, sizeof(act));
    act.sa_handler = SIG_IGN;
    act.sa_flags   = SA_SIGINFO;
    sigemptyset(&act.sa_mask);

    // verify SIGSTOP and SIGKILL could not set signal-handler
    int ret = 0;

    ret                 = syscall(SYS_rt_sigaction, SIGSEGV, NULL, (struct sigaction*)0x1, 8);
    char* error_message = strerror(errno);
    printf("errno: %s\n", error_message);
    assert(ret != 0 && errno == EFAULT);

    ret     = sigaction(SIGSTOP, &act, NULL);
    assert(ret != 0 && errno == EINVAL);

    ret = sigaction(SIGKILL, &act, NULL);
    assert(ret != 0);

    const int THREADS_COUNT = 10;
    pthread_t tid[THREADS_COUNT];
    thread_data* tds = (thread_data*)malloc(sizeof(thread_data) * THREADS_COUNT);

    int i = 0;
    for (i = 0; i < THREADS_COUNT; i++)
    {
        tds[i].tid = i + 1;
    }

    for (i = 0; i < THREADS_COUNT; i++)
    {
        pthread_create(&tid[i], NULL, set_sigaction, &tds[i]);
    }

    for (i = 0; i < THREADS_COUNT; i++)
    {
        pthread_join(tid[i], NULL);
    }

    for (i = 0; i < THREADS_COUNT; i++)
    {
        printf("[thread %d] finished.\n", tds[i].tid);
    }
    return 0;
}
