
#include "mkcert.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/provider.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
#include <openssl/rand.h>

static const int NUM_BITS = 2048;
static const int SERIAL = 0;
static const int NUM_YEARS = 20;

// Upstream assumes every OpenSSL call succeeds. On an iPad 3 (iOS 8.4.1,
// armv7) EVP_PKEY_CTX_new_id() returned NULL and EVP_PKEY_keygen() then
// crashed on it, so every step is checked and failures are described here
// (including OpenSSL's error queue) for the UI to show.
static char lastError[4096];

static void appendError(const char* format, ...) {
    size_t used = strlen(lastError);
    if (used >= sizeof(lastError) - 1) {
        return;
    }
    va_list args;
    va_start(args, format);
    vsnprintf(lastError + used, sizeof(lastError) - used, format, args);
    va_end(args);
}

static int appendOpenSSLError(const char* str, size_t len, void* context) {
    appendError("  %.*s", (int)len, str);
    if (len == 0 || str[len - 1] != '\n') {
        appendError("\n");
    }
    return 1;
}

static void recordFailure(const char* step) {
    appendError("%s failed\n", step);
    ERR_print_errors_cb(appendOpenSSLError, NULL);
}

const char* mkcertLastError(void) {
    return lastError;
}

static EVP_PKEY* generateRsaKey(int bits) {
    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, NULL);
    if (ctx == NULL) {
        recordFailure("EVP_PKEY_CTX_new_id(EVP_PKEY_RSA)");

        // The RSA implementation lives in the "default" provider, which OpenSSL
        // normally activates implicitly. Try to load it explicitly and retry.
        appendError("default provider available: %d\n", OSSL_PROVIDER_available(NULL, "default"));
        if (OSSL_PROVIDER_load(NULL, "default") == NULL) {
            recordFailure("OSSL_PROVIDER_load(default)");
        }
        ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, NULL);
        if (ctx == NULL) {
            recordFailure("EVP_PKEY_CTX_new_id(EVP_PKEY_RSA) after loading the default provider");
            return NULL;
        }
        appendError("Retry after loading the default provider succeeded\n");
    }

    EVP_PKEY* pk = NULL;
    if (EVP_PKEY_keygen_init(ctx) <= 0) {
        recordFailure("EVP_PKEY_keygen_init");
    }
    else if (EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, bits) <= 0) {
        recordFailure("EVP_PKEY_CTX_set_rsa_keygen_bits");
    }
    else if (EVP_PKEY_keygen(ctx, &pk) <= 0) {
        recordFailure("EVP_PKEY_keygen");
        pk = NULL;
    }

    EVP_PKEY_CTX_free(ctx);
    return pk;
}

static int mkcert(X509 **x509p, EVP_PKEY **pkeyp, int bits, int serial, int years) {
    *x509p = NULL;
    *pkeyp = NULL;

    EVP_PKEY* pk = generateRsaKey(bits);
    if (pk == NULL) {
        return 0;
    }

    X509* cert = X509_new();
    if (cert == NULL) {
        recordFailure("X509_new");
        EVP_PKEY_free(pk);
        return 0;
    }

    X509_set_version(cert, 2);
    ASN1_INTEGER_set(X509_get_serialNumber(cert), serial);

    ASN1_TIME* before = ASN1_STRING_dup(X509_get0_notBefore(cert));
    ASN1_TIME* after = ASN1_STRING_dup(X509_get0_notAfter(cert));

    X509_gmtime_adj(before, 0);
    X509_gmtime_adj(after, 60 * 60 * 24 * 365 * years);

    X509_set1_notBefore(cert, before);
    X509_set1_notAfter(cert, after);

    ASN1_STRING_free(before);
    ASN1_STRING_free(after);

    if (!X509_set_pubkey(cert, pk)) {
        recordFailure("X509_set_pubkey");
        goto fail;
    }

    X509_NAME* name = X509_get_subject_name(cert);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                               (const unsigned char*)"NVIDIA GameStream Client",
                               -1, -1, 0);
    X509_set_issuer_name(cert, name);

    if (!X509_sign(cert, pk, EVP_sha256())) {
        recordFailure("X509_sign");
        goto fail;
    }

    *x509p = cert;
    *pkeyp = pk;
    return 1;

fail:
    X509_free(cert);
    EVP_PKEY_free(pk);
    return 0;
}

struct CertKeyPair generateCertKeyPair(void) {
    X509 *x509 = NULL;
    EVP_PKEY *pkey = NULL;
    PKCS12 *p12 = NULL;

    lastError[0] = 0;

    if (!mkcert(&x509, &pkey, NUM_BITS, SERIAL, NUM_YEARS)) {
        appendError("\n%s\n", OpenSSL_version(OPENSSL_VERSION));
        return (CertKeyPair){NULL, NULL, NULL};
    }

    char* pass = "limelight";
    p12 = PKCS12_create(pass,
                        "GameStream",
                        pkey,
                        x509,
                        NULL,
                        NID_pbe_WithSHA1And3_Key_TripleDES_CBC,
                        // Encrypt the certificate bag too. Moonlight 2.x (OpenSSL 1.0
                        // defaults) always produced an encrypted certificate bag, which is
                        // what old iOS versions' SecPKCS12Import are known to accept.
                        // Upstream uses an unencrypted bag to avoid OpenSSL 3's legacy
                        // provider (needed for the old RC2 default), but 3DES lives in the
                        // default provider, so use that instead.
                        NID_pbe_WithSHA1And3_Key_TripleDES_CBC,
                        2048,
                        -1, // disable the automatic MAC
                        0);
    if (p12 == NULL) {
        recordFailure("PKCS12_create");
        appendError("\n%s\n", OpenSSL_version(OPENSSL_VERSION));
        X509_free(x509);
        EVP_PKEY_free(pkey);
        return (CertKeyPair){NULL, NULL, NULL};
    }

    // MAC it ourselves with SHA1 since iOS refuses to load anything else.
    if (!PKCS12_set_mac(p12, pass, -1, NULL, 0, 1, EVP_sha1())) {
        recordFailure("PKCS12_set_mac");
    }

    return (CertKeyPair){x509, pkey, p12};
}

void freeCertKeyPair(struct CertKeyPair certKeyPair) {
    X509_free(certKeyPair.x509);
    EVP_PKEY_free(certKeyPair.pkey);
    PKCS12_free(certKeyPair.p12);
}
