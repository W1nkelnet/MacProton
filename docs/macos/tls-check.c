/*
 * TLS checks for Wine on macOS.
 *
 * Counts the certificates in the ROOT system store (filled by crypt32 from
 * the macOS keychain; engines with their own TLS stack, like UnityTls, read
 * their trust anchors from it) and fetches a page over HTTPS with WinHTTP,
 * which goes through schannel and therefore needs GnuTLS.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 tls-check.c -o tls-check.exe -lcrypt32 -lwinhttp
 * usage: tls-check.exe [host]
 */
#include <windows.h>
#include <wincrypt.h>
#include <winhttp.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    const char *host = argc > 1 ? argv[1] : "store.steampowered.com";
    WCHAR whost[256];
    PCCERT_CONTEXT cert = NULL;
    HCERTSTORE store;
    HINTERNET session, connection, request;
    DWORD count = 0, status = 0, size = sizeof(status);
    int failures = 0;

    if ((store = CertOpenSystemStoreA(0, "ROOT")))
    {
        while ((cert = CertEnumCertificatesInStore(store, cert))) count++;
        CertCloseStore(store, 0);
    }
    printf("%s ROOT store: %lu certificates\n", count > 10 ? "OK:  " : "FAIL:", count);
    if (count <= 10) failures++;

    MultiByteToWideChar(CP_ACP, 0, host, -1, whost, ARRAYSIZE(whost));
    session = WinHttpOpen(L"tls-check", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    connection = session ? WinHttpConnect(session, whost, INTERNET_DEFAULT_HTTPS_PORT, 0) : NULL;
    request = connection ? WinHttpOpenRequest(connection, L"GET", L"/", NULL, NULL, NULL, WINHTTP_FLAG_SECURE) : NULL;
    if (request && WinHttpSendRequest(request, NULL, 0, NULL, 0, 0, 0) && WinHttpReceiveResponse(request, NULL)
        && WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &status, &size, NULL))
        printf("OK:   WinHTTP https://%s/ -> HTTP %lu\n", host, status);
    else
    {
        printf("FAIL: WinHTTP https://%s/ error %lu\n", host, GetLastError());
        failures++;
    }

    printf("%s: %d failure(s)\n", failures ? "FAIL" : "OK", failures);
    return failures;
}
