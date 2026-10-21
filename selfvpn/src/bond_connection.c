#include <string.h>
#include <arpa/inet.h>

#include "bond_connection.h"
#include "bond_trans_tool.h"
#include "core.h"

int bond_connection_send_auth_request(int sockfd, const char *secret, const char *sn)
{
    uint8_t buf[2 + BOND_AUTH_REQUEST_MAX];
    int secret_len;
    int sn_len;
    int payload_len;
    uint16_t be;

    if (NULL == secret || NULL == sn)
        return -1;

    secret_len = (int)strlen(secret);
    sn_len = (int)strlen(sn);
    if (secret_len >= BOND_AUTH_LEN || sn_len >= BOND_AUTH_LEN)
        return -1;

    payload_len = 2 + secret_len + 2 + sn_len;
    be = htons((uint16_t)payload_len);
    memcpy(buf, &be, 2);
    be = htons((uint16_t)secret_len);
    memcpy(buf + 2, &be, 2);
    memcpy(buf + 4, secret, secret_len);
    be = htons((uint16_t)sn_len);
    memcpy(buf + 4 + secret_len, &be, 2);
    memcpy(buf + 6 + secret_len, sn, sn_len);

    return core_write_exact(sockfd, buf, (size_t)payload_len + 2, BOND_AUTH_TIMEOUT_MS);
}

int bond_auth_request_length(const uint8_t *buf, uint32_t len, uint32_t *need)
{
    uint16_t payload_len;

    if (NULL == buf || NULL == need || len < 2)
        return -1;

    memcpy(&payload_len, buf, sizeof(payload_len));
    payload_len = ntohs(payload_len);
    if (payload_len < 4 || payload_len > BOND_AUTH_REQUEST_MAX)
        return -1;

    *need = (uint32_t)payload_len + 2;
    return 0;
}

int bond_auth_request_verify(const uint8_t *buf, uint32_t len, const char *secret,
                             char *sn, size_t sn_len)
{
    uint16_t payload_len;
    uint16_t secret_len;
    uint16_t client_sn_len;
    char client_secret[BOND_AUTH_LEN];
    uint32_t offset;

    if (NULL == buf || NULL == secret || NULL == sn || 0 == sn_len || len < 6)
        return -1;

    memcpy(&payload_len, buf, sizeof(payload_len));
    payload_len = ntohs(payload_len);
    if (payload_len + 2 != len)
        return -1;

    offset = 2;
    memcpy(&secret_len, buf + offset, sizeof(secret_len));
    secret_len = ntohs(secret_len);
    offset += 2;
    if (secret_len >= BOND_AUTH_LEN || offset + secret_len + 2 > len)
        return -1;
    memcpy(client_secret, buf + offset, secret_len);
    client_secret[secret_len] = '\0';
    offset += secret_len;

    memcpy(&client_sn_len, buf + offset, sizeof(client_sn_len));
    client_sn_len = ntohs(client_sn_len);
    offset += 2;
    if (client_sn_len >= BOND_AUTH_LEN || client_sn_len >= sn_len ||
        offset + client_sn_len != len)
        return -1;

    memcpy(sn, buf + offset, client_sn_len);
    sn[client_sn_len] = '\0';

    if (0 != strcmp(client_secret, secret))
        return -1;

    return 0;
}

void bond_auth_response_build(uint8_t *buf, uint8_t status,
                              uint32_t assigned_ip, uint32_t server_ip)
{
    uint16_t be;
    uint32_t ip;

    if (NULL == buf)
        return;

    be = htons(BOND_AUTH_RESPONSE_LEN);
    memcpy(buf, &be, sizeof(be));
    buf[2] = status;
    ip = htonl(assigned_ip);
    memcpy(buf + 3, &ip, 4);
    ip = htonl(server_ip);
    memcpy(buf + 7, &ip, 4);
}

int bond_connection_recv_auth_response(int sockfd, bond_auth_result_t *result)
{
    uint8_t buf[2 + BOND_AUTH_RESPONSE_LEN];
    uint16_t payload_len;
    uint32_t ip;

    if (NULL == result)
        return -1;

    if (0 != core_read_exact(sockfd, buf, 2, BOND_AUTH_TIMEOUT_MS))
        return -1;

    memcpy(&payload_len, buf, 2);
    payload_len = ntohs(payload_len);
    if (payload_len != BOND_AUTH_RESPONSE_LEN)
        return -1;

    if (0 != core_read_exact(sockfd, buf + 2, payload_len, BOND_AUTH_TIMEOUT_MS))
        return -1;

    result->status = buf[2];
    memcpy(&ip, buf + 3, 4);
    result->assigned_ip = ntohl(ip);
    memcpy(&ip, buf + 7, 4);
    result->server_ip = ntohl(ip);

    return 0;
}
