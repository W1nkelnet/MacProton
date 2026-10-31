/*
 * Checks Wine's synchronization objects, written for fsync on macOS: event ping-pong between threads,
 * semaphores, recursive mutexes, wait-any and wait-all, APCs, timeouts, manual-reset events,
 * abandoned mutexes, SignalObjectAndWait, waits longer than fsync's 250 ms sleep cap, and
 * ping-pong with a child process. Prints round-trip times and "PASSED: 0 failures".
 *
 *   x86_64-w64-mingw32-gcc -O2 -o synctest.exe synctest.c
 *   WINEFSYNC=1 wine synctest.exe
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static int failures;
#define CHECK(c, ...) do { if (!(c)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static double now_ms(void)
{
    LARGE_INTEGER f, c; QueryPerformanceFrequency(&f); QueryPerformanceCounter(&c);
    return c.QuadPart * 1000.0 / f.QuadPart;
}

/* 1. ping-pong */
static HANDLE ping, pong; static int pp_n = 100000;
static DWORD WINAPI pp_thread(void *arg)
{
    for (int i = 0; i < pp_n; i++) { WaitForSingleObject(ping, INFINITE); SetEvent(pong); }
    return 0;
}
static void test_pingpong(void)
{
    ping = CreateEventA(NULL, FALSE, FALSE, NULL); pong = CreateEventA(NULL, FALSE, FALSE, NULL);
    HANDLE t = CreateThread(NULL, 0, pp_thread, NULL, 0, NULL);
    double t0 = now_ms();
    for (int i = 0; i < pp_n; i++) { SetEvent(ping); CHECK(WaitForSingleObject(pong, 5000) == WAIT_OBJECT_0, "pong %d", i); }
    double t1 = now_ms();
    WaitForSingleObject(t, INFINITE);
    printf("event ping-pong: %.2f us per round trip\n", (t1 - t0) * 1000 / pp_n);
    CloseHandle(t); CloseHandle(ping); CloseHandle(pong);
}

/* 2. semaphore producer/consumer */
static HANDLE sem; static volatile LONG consumed; static volatile LONG stop_flag;
static DWORD WINAPI consumer(void *arg)
{
    while (1) {
        DWORD r = WaitForSingleObject(sem, 2000);
        if (r != WAIT_OBJECT_0) break;
        if (InterlockedIncrement(&consumed) < 0) break;
        if (stop_flag && consumed >= 80000) break;
    }
    return 0;
}
static void test_semaphore(void)
{
    HANDLE th[6]; LONG prev;
    sem = CreateSemaphoreA(NULL, 0, 1000, NULL);
    CHECK(!ReleaseSemaphore(sem, 1001, NULL) && GetLastError() == ERROR_TOO_MANY_POSTS, "limit");
    for (int i = 0; i < 6; i++) th[i] = CreateThread(NULL, 0, consumer, NULL, 0, NULL);
    for (int i = 0; i < 40000; i++) while (!ReleaseSemaphore(sem, 2, &prev)) Sleep(0);
    stop_flag = 1;
    WaitForMultipleObjects(6, th, TRUE, 20000);
    CHECK(consumed == 80000, "consumed %ld", consumed);
    for (int i = 0; i < 6; i++) CloseHandle(th[i]);
    CloseHandle(sem);
}

/* 3. mutex contention */
static HANDLE mtx; static int counter;
static DWORD WINAPI mtx_thread(void *arg)
{
    for (int i = 0; i < 20000; i++) {
        WaitForSingleObject(mtx, INFINITE);
        WaitForSingleObject(mtx, INFINITE); /* recursive */
        int c = counter; counter = c + 1;
        ReleaseMutex(mtx); ReleaseMutex(mtx);
    }
    return 0;
}
static void test_mutex(void)
{
    HANDLE th[8];
    mtx = CreateMutexA(NULL, FALSE, NULL);
    for (int i = 0; i < 8; i++) th[i] = CreateThread(NULL, 0, mtx_thread, NULL, 0, NULL);
    CHECK(WaitForMultipleObjects(8, th, TRUE, 60000) == WAIT_OBJECT_0, "mutex threads");
    CHECK(counter == 160000, "counter %d", counter);
    CHECK(!ReleaseMutex(mtx) && GetLastError() == ERROR_NOT_OWNER, "not owner");
    for (int i = 0; i < 8; i++) CloseHandle(th[i]);
}

/* 4. wait any */
static HANDLE evs[5];
static DWORD WINAPI set_later(void *arg) { Sleep(30); SetEvent(evs[(INT_PTR)arg]); return 0; }
static void test_wait_any(void)
{
    for (int i = 0; i < 5; i++) evs[i] = CreateEventA(NULL, FALSE, FALSE, NULL);
    for (int k = 0; k < 5; k++) {
        HANDLE t = CreateThread(NULL, 0, set_later, (void *)(INT_PTR)((k * 3) % 5), 0, NULL);
        DWORD r = WaitForMultipleObjects(5, evs, FALSE, 3000);
        CHECK(r == WAIT_OBJECT_0 + (k * 3) % 5, "wait any got %lu want %d", r, (k * 3) % 5);
        WaitForSingleObject(t, INFINITE); CloseHandle(t);
    }
    /* multi-wait ping-pong: many signals while waiting on several */
    double t0 = now_ms();
    for (int k = 0; k < 2000; k++) {
        HANDLE t = CreateThread(NULL, 0, set_later, (void *)(INT_PTR)4, CREATE_SUSPENDED, NULL);
        ResumeThread(t); CloseHandle(t);
        if (k > 3) break;
    }
    for (int k = 0; k < 5; k++) WaitForMultipleObjects(5, evs, FALSE, 1000);
    (void)t0;
}

/* 5. wait all */
static DWORD WINAPI set_all(void *arg) { for (int i = 0; i < 5; i++) { Sleep(10); SetEvent(evs[i]); } return 0; }
static void test_wait_all(void)
{
    for (int i = 0; i < 5; i++) ResetEvent(evs[i]);
    HANDLE t = CreateThread(NULL, 0, set_all, NULL, 0, NULL);
    DWORD r = WaitForMultipleObjects(5, evs, TRUE, 3000);
    CHECK(r == WAIT_OBJECT_0, "wait all %lu", r);
    for (int i = 0; i < 5; i++) CHECK(WaitForSingleObject(evs[i], 0) == WAIT_TIMEOUT, "auto reset %d", i);
    WaitForSingleObject(t, INFINITE); CloseHandle(t);
}

/* 6. APC */
static volatile LONG apc_ran;
static void CALLBACK apc(ULONG_PTR p) { InterlockedIncrement(&apc_ran); }
static HANDLE apc_target_ev;
static DWORD WINAPI alert_waiter(void *arg)
{
    DWORD r = WaitForSingleObjectEx(apc_target_ev, 5000, TRUE);
    return r;
}
static void test_apc(void)
{
    DWORD code;
    apc_target_ev = CreateEventA(NULL, FALSE, FALSE, NULL);
    for (int k = 0; k < 20; k++) {
        HANDLE t = CreateThread(NULL, 0, alert_waiter, NULL, 0, NULL);
        Sleep(5);
        double t0 = now_ms();
        QueueUserAPC(apc, t, 0);
        WaitForSingleObject(t, 5000);
        double dt = now_ms() - t0;
        GetExitCodeThread(t, &code);
        CHECK(code == WAIT_IO_COMPLETION, "alertable wait returned %lu", code);
        CHECK(dt < 1000, "apc took %.0f ms", dt);
        CloseHandle(t);
    }
    CHECK(apc_ran == 20, "apc ran %ld", apc_ran);
    /* alertable wait that gets the event */
    HANDLE t = CreateThread(NULL, 0, alert_waiter, NULL, 0, NULL);
    Sleep(10); SetEvent(apc_target_ev);
    WaitForSingleObject(t, 5000); GetExitCodeThread(t, &code);
    CHECK(code == WAIT_OBJECT_0, "alertable wait event %lu", code);
    CloseHandle(t);
    CHECK(SleepEx(0, TRUE) == 0, "sleepex");
    QueueUserAPC(apc, GetCurrentThread(), 0);
    CHECK(SleepEx(1000, TRUE) == WAIT_IO_COMPLETION, "sleepex apc");
}

/* 7. timeouts */
static void test_timeout(void)
{
    HANDLE ev = CreateEventA(NULL, TRUE, FALSE, NULL);
    double t0 = now_ms();
    DWORD r = WaitForSingleObject(ev, 100);
    double dt = now_ms() - t0;
    CHECK(r == WAIT_TIMEOUT && dt >= 95 && dt < 300, "timeout %lu %.1f ms", r, dt);
    t0 = now_ms();
    r = WaitForMultipleObjects(1, &ev, FALSE, 0);
    CHECK(r == WAIT_TIMEOUT, "zero timeout");
    HANDLE two[2] = { ev, CreateEventA(NULL, FALSE, FALSE, NULL) };
    t0 = now_ms();
    r = WaitForMultipleObjectsEx(2, two, FALSE, 80, TRUE);
    dt = now_ms() - t0;
    CHECK(r == WAIT_TIMEOUT && dt >= 75 && dt < 300, "multi timeout %lu %.1f ms", r, dt);
    printf("timeouts: 100 ms wait took %.1f ms\n", dt);
}

/* 8. manual event wakes all */
static HANDLE gate; static volatile LONG woke;
static DWORD WINAPI gate_waiter(void *arg) { if (WaitForSingleObject(gate, 5000) == WAIT_OBJECT_0) InterlockedIncrement(&woke); return 0; }
static void test_manual(void)
{
    HANDLE th[8];
    gate = CreateEventA(NULL, TRUE, FALSE, NULL);
    for (int i = 0; i < 8; i++) th[i] = CreateThread(NULL, 0, gate_waiter, NULL, 0, NULL);
    Sleep(50); SetEvent(gate);
    WaitForMultipleObjects(8, th, TRUE, 5000);
    CHECK(woke == 8, "woke %ld", woke);
    for (int i = 0; i < 8; i++) CloseHandle(th[i]);
}

/* 9. abandoned mutex */
static HANDLE amtx;
static DWORD WINAPI grab_and_exit(void *arg) { WaitForSingleObject(amtx, INFINITE); return 0; }
static void test_abandoned(void)
{
    amtx = CreateMutexA(NULL, FALSE, NULL);
    HANDLE t = CreateThread(NULL, 0, grab_and_exit, NULL, 0, NULL);
    CHECK(WaitForSingleObject(t, 5000) == WAIT_OBJECT_0, "thread handle wait");
    CHECK(WaitForSingleObject(amtx, 2000) == WAIT_ABANDONED, "abandoned");
    ReleaseMutex(amtx);
    CloseHandle(t);
}

/* 10. SignalObjectAndWait */
static DWORD WINAPI soaw_thread(void *arg)
{
    for (int i = 0; i < 1000; i++) if (SignalObjectAndWait(pong, ping, 5000, FALSE) != WAIT_OBJECT_0) return 1;
    SetEvent(pong);
    return 0;
}
static void test_soaw(void)
{
    DWORD code;
    ping = CreateEventA(NULL, FALSE, FALSE, NULL); pong = CreateEventA(NULL, FALSE, FALSE, NULL);
    HANDLE t = CreateThread(NULL, 0, soaw_thread, NULL, 0, NULL);
    for (int i = 0; i < 1000; i++) CHECK(SignalObjectAndWait(ping, pong, 5000, FALSE) == WAIT_OBJECT_0 || i == 0, "soaw %d", i);
    WaitForSingleObject(t, 5000); GetExitCodeThread(t, &code);
    CHECK(code == 0, "soaw thread %lu", code);
    CloseHandle(t);
}

/* 11. cross process */
static void child(void)
{
    HANDLE a = OpenEventA(EVENT_ALL_ACCESS, FALSE, "synctest-a"), b = OpenEventA(EVENT_ALL_ACCESS, FALSE, "synctest-b");
    HANDLE m = OpenSemaphoreA(SEMAPHORE_ALL_ACCESS, FALSE, "synctest-s");
    for (int i = 0; i < 20000; i++) { if (WaitForSingleObject(a, 5000)) exit(2); SetEvent(b); }
    HANDLE both[2] = { a, m };
    for (int i = 0; i < 200; i++) { DWORD r = WaitForMultipleObjects(2, both, FALSE, 5000); if (r > 1) exit(3); SetEvent(b); }
    exit(0);
}
static void test_cross_process(const char *self)
{
    HANDLE a = CreateEventA(NULL, FALSE, FALSE, "synctest-a"), b = CreateEventA(NULL, FALSE, FALSE, "synctest-b");
    HANDLE m = CreateSemaphoreA(NULL, 0, 10, "synctest-s");
    char cmd[MAX_PATH + 16]; STARTUPINFOA si = { sizeof(si) }; PROCESS_INFORMATION pi; DWORD code;
    snprintf(cmd, sizeof(cmd), "\"%s\" child", self);
    CHECK(CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi), "create process");
    double t0 = now_ms();
    for (int i = 0; i < 20000; i++) { SetEvent(a); CHECK(WaitForSingleObject(b, 5000) == WAIT_OBJECT_0, "cross %d", i); }
    double t1 = now_ms();
    for (int i = 0; i < 200; i++) { if (i & 1) SetEvent(a); else ReleaseSemaphore(m, 1, NULL); CHECK(WaitForSingleObject(b, 5000) == WAIT_OBJECT_0, "cross multi %d", i); }
    CHECK(WaitForSingleObject(pi.hProcess, 10000) == WAIT_OBJECT_0, "child exit");
    GetExitCodeProcess(pi.hProcess, &code);
    CHECK(code == 0, "child code %lu", code);
    printf("cross-process ping-pong: %.2f us per round trip\n", (t1 - t0) * 1000 / 20000);
}

static HANDLE lw[2];
static DWORD WINAPI set_much_later(void *arg) { Sleep(700); SetEvent(lw[(INT_PTR)arg]); return 0; }

/* waits longer than the fsync sleep cap must neither time out nor end early */
static void test_long_wait(void)
{
    lw[0] = CreateEventA(NULL, FALSE, FALSE, NULL);
    lw[1] = CreateEventA(NULL, TRUE, FALSE, NULL);
    for (int kind = 0; kind < 3; kind++)
    {
        HANDLE t = CreateThread(NULL, 0, set_much_later, (void *)(INT_PTR)(kind == 1), 0, NULL);
        double t0 = now_ms();
        DWORD r;
        if (kind == 0) r = WaitForSingleObject(lw[0], INFINITE);
        else if (kind == 1) r = WaitForMultipleObjects(2, lw, FALSE, INFINITE);
        else { SetEvent(lw[1]); r = WaitForMultipleObjects(2, lw, TRUE, INFINITE); }
        double dt = now_ms() - t0;
        CHECK(r == (kind == 1 ? WAIT_OBJECT_0 + 1 : WAIT_OBJECT_0), "long wait %d returned %lu", kind, r);
        CHECK(dt > 600, "long wait %d ended after %.0f ms", kind, dt);
        WaitForSingleObject(t, INFINITE); CloseHandle(t); ResetEvent(lw[1]);
    }
    double t0 = now_ms();
    CHECK(WaitForSingleObject(lw[0], 1000) == WAIT_TIMEOUT, "timed long wait");
    CHECK(now_ms() - t0 > 950, "timed long wait ended after %.0f ms", now_ms() - t0);
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "child")) { child(); return 0; }
    setvbuf(stdout, NULL, _IONBF, 0);
    test_pingpong(); printf("pingpong done\n");
    test_semaphore(); printf("semaphore done\n");
    test_mutex(); printf("mutex done\n");
    test_wait_any(); printf("wait any done\n");
    test_wait_all(); printf("wait all done\n");
    test_apc(); printf("apc done\n");
    test_timeout(); printf("timeout done\n");
    test_manual(); printf("manual done\n");
    test_abandoned(); printf("abandoned done\n");
    test_soaw(); printf("soaw done\n");
    test_long_wait(); printf("long wait done\n");
    test_cross_process(argv[0]); printf("cross process done\n");
    printf("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
    return failures != 0;
}
