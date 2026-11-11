/* Clean-room minimal <ctype.h> for macOS arm64 compile checks (C11 7.4). Compile checks only. */
#ifndef CLEANROOM_CTYPE_H
#define CLEANROOM_CTYPE_H
int isalnum(int);
int isalpha(int);
int isblank(int);
int iscntrl(int);
int isdigit(int);
int isgraph(int);
int islower(int);
int isprint(int);
int ispunct(int);
int isspace(int);
int isupper(int);
int isxdigit(int);
int tolower(int);
int toupper(int);
#endif
