/* lib/secrets_pbkdf2.c — PKCS5 PBKDF2-HMAC-SHA256 (matches Python hashlib.pbkdf2_hmac). */
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int hex_decode(const char *hex, unsigned char *out, size_t out_max, size_t *out_len) {
    size_t n = strlen(hex);
    size_t i;
    int hi, lo;
    if (n % 2 != 0) return -1;
    if (out_max < n / 2) return -1;
    for (i = 0; i < n / 2; i++) {
        hi = hex_nibble(hex[i * 2]);
        lo = hex_nibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[i] = (unsigned char)((hi << 4) | lo);
    }
    *out_len = n / 2;
    return 0;
}

int main(int argc, char **argv) {
    const char *pass_env = "SECRETS_PBKDF2_PASS";
    const char *pass;
    const char *salt_hex;
    int iter;
    unsigned char salt[256];
    size_t salt_len = 0;
    unsigned char key[32];
    size_t i;

    if (argc != 3) {
        fprintf(stderr, "usage: secrets_pbkdf2 SALT_HEX ITERATIONS\n");
        return 2;
    }
    pass = getenv(pass_env);
    if (!pass) {
        fprintf(stderr, "missing env %s\n", pass_env);
        return 2;
    }
    salt_hex = argv[1];
    iter = atoi(argv[2]);
    if (iter < 1) return 2;
    if (hex_decode(salt_hex, salt, sizeof(salt), &salt_len) != 0) return 2;

    if (PKCS5_PBKDF2_HMAC(pass, (int)strlen(pass), salt, (int)salt_len, iter,
                          EVP_sha256(), 32, key) != 1) {
        return 1;
    }
    for (i = 0; i < 32; i++) {
        printf("%02x", key[i]);
    }
    printf("\n");
    return 0;
}
