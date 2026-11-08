#include "CLocalSupport.h"
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <locale.h>
#include <ncurses.h>
#include <wchar.h>
#include <string.h>

int tm_lock_acquire(const char *path) {
    int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) { close(fd); return -1; }
    return fd;
}
int tm_lock_held(const char *path) {
    int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    int held = 0;
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) held = (errno == EWOULDBLOCK) ? 1 : -1;
    else flock(fd, LOCK_UN);
    close(fd);
    return held;
}
void tm_lock_release(int fd) { if (fd >= 0) { flock(fd, LOCK_UN); close(fd); } }
int tm_terminal_open(void) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) return -1;
    setlocale(LC_ALL, "");
    if (initscr() == NULL) return -1;
    raw(); noecho(); keypad(stdscr, TRUE); nodelay(stdscr, TRUE); curs_set(0);
    return 0;
}
void tm_terminal_close(void) { endwin(); }
void tm_terminal_clear(void) { erase(); }
void tm_terminal_refresh(void) { refresh(); }
int tm_terminal_rows(void) { return LINES; }
int tm_terminal_columns(void) { return COLS; }
int tm_terminal_key(void) { return getch(); }
void tm_terminal_draw(int row, int col, const char *text, int width, int emphasis) {
    if (row < 0 || row >= LINES || col < 0 || col >= COLS || width <= 0) return;
    if (width > COLS - col) width = COLS - col;
    if (emphasis == 1) attron(A_BOLD);
    if (emphasis == 2) attron(A_REVERSE);
    // Convert UTF-8 to display-width-aware characters; never emit control sequences from agent output.
    mbstate_t state = {0};
    const char *cursor = text;
    int columns = 0;
    move(row, col);
    while (*cursor) {
        wchar_t character;
        size_t length = mbrtowc(&character, cursor, strlen(cursor), &state);
        if (length == (size_t)-1 || length == (size_t)-2 || length == 0) break;
        int cells = wcwidth(character);
        if (cells < 0) { cursor += length; continue; }
        if (columns + cells > width) break;
        addnstr(cursor, (int)length);
        columns += cells;
        cursor += length;
    }
    if (emphasis == 1) attroff(A_BOLD);
    if (emphasis == 2) attroff(A_REVERSE);
}
int tm_key_up(void) { return KEY_UP; }
int tm_key_down(void) { return KEY_DOWN; }
int tm_key_page_up(void) { return KEY_PPAGE; }
int tm_key_page_down(void) { return KEY_NPAGE; }
int tm_key_backspace(void) { return KEY_BACKSPACE; }
int tm_key_resize(void) { return KEY_RESIZE; }
