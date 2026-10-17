// EXPECT: 3
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static char buf[64];
static int count_char(const char *s, char c) { int n = 0; while (*s) { if (*s++ == c) n++; } return n; }
int main(void) {
    const char *words = "the quick brown fox jumps over the lazy dog";
    strcpy(buf, "hello");
    strcat(buf, ", world");
    printf("%s|%d|%d\n", buf, (int)strlen(buf), count_char(words, 'o'));
    printf("%d %s\n", strcmp("abc", "abd") < 0, strchr(words, 'q'));
    char tmp[32];
    snprintf(tmp, sizeof tmp, "%05d-%x", 42, 255);
    printf("%s\n", tmp);
    char *dup = strdup("dup");
    printf("%s %d\n", dup, atoi("123") + atoi("-23"));
    free(dup);
    return count_char(words, 'e');
}
