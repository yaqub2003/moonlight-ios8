//
//  mkcert.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/16/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#ifndef Limelight_mkcert_h
#define Limelight_mkcert_h

#include <openssl/x509v3.h>
#include <openssl/pkcs12.h>

typedef struct CertKeyPair {
    X509 *x509;
    EVP_PKEY *pkey;
    PKCS12 *p12;
} CertKeyPair;

// Returns a pair with NULL members on failure; see mkcertLastError()
struct CertKeyPair generateCertKeyPair(void);
// Description of the last failure in generateCertKeyPair(), including OpenSSL's error queue
const char* mkcertLastError(void);
void freeCertKeyPair(CertKeyPair);
#endif

