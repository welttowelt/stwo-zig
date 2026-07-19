#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

int main(void) {
    if (open("/anchor/cp11_dump", O_RDONLY) >= 0) return 10;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 11;
    struct sockaddr_in address = {
        .sin_family = AF_INET,
        .sin_port = htons(53),
        .sin_addr = {.s_addr = htonl(0x01010101)},
    };
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) return 12;
    close(fd);

    pid_t child = fork();
    if (child < 0) return 13;
    if (child == 0) {
        sleep(2);
        int background = open("/out/background-child", O_CREAT | O_WRONLY, 0600);
        if (background >= 0) close(background);
        _exit(0);
    }
    int marker = open("/out/probe-pass", O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (marker < 0) return 14;
    close(marker);
    return 0;
}
