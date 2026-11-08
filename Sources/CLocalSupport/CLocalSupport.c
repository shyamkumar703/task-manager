#include "CLocalSupport.h"
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <locale.h>
#include <signal.h>
#include <termios.h>
#include <ncurses.h>
#include <wchar.h>
#include <string.h>
#include <stdlib.h>

static int tm_colors = 0;

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
    tm_colors = has_colors() && getenv("NO_COLOR") == NULL;
    if (tm_colors) {
        start_color(); use_default_colors();
        if (COLORS < 8 || COLOR_PAIRS < 8) tm_colors = 0;
        else {
            init_pair(1, COLOR_GREEN, -1);
            init_pair(2, COLOR_WHITE, COLOR_BLUE);
            init_pair(3, COLOR_WHITE, -1);
            init_pair(4, COLOR_YELLOW, -1);
            init_pair(5, COLOR_GREEN, -1);
            init_pair(6, COLOR_RED, -1);
        }
    }
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
    attr_t style = A_NORMAL;
    switch (emphasis) {
        case 1: style = A_BOLD | (tm_colors ? COLOR_PAIR(1) : 0); break;
        case 2: style = tm_colors ? A_BOLD | COLOR_PAIR(2) : A_REVERSE; break;
        case 3: style = A_DIM | (tm_colors ? COLOR_PAIR(3) : 0); break;
        case 4: style = A_BOLD | (tm_colors ? COLOR_PAIR(4) : 0); break;
        case 5: style = tm_colors ? COLOR_PAIR(5) : A_BOLD; break;
        case 6: style = A_BOLD | (tm_colors ? COLOR_PAIR(6) : 0); break;
        case 7: style = A_DIM; break;
        case 8: style = A_BOLD | (tm_colors ? COLOR_PAIR(1) : A_UNDERLINE); break;
    }
    attrset(style);
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
    attrset(A_NORMAL);
}
int tm_key_up(void) { return KEY_UP; }
int tm_key_down(void) { return KEY_DOWN; }
int tm_key_left(void) { return KEY_LEFT; }
int tm_key_right(void) { return KEY_RIGHT; }
int tm_key_page_up(void) { return KEY_PPAGE; }
int tm_key_page_down(void) { return KEY_NPAGE; }
int tm_key_backspace(void) { return KEY_BACKSPACE; }
int tm_key_resize(void) { return KEY_RESIZE; }

int tm_terminal_give_foreground(int process_group) {
    struct sigaction ignored = {0}, previous;
    ignored.sa_handler = SIG_IGN;
    sigemptyset(&ignored.sa_mask);
    sigaction(SIGTTOU, &ignored, &previous);
    int result = tcsetpgrp(STDIN_FILENO, process_group);
    sigaction(SIGTTOU, &previous, NULL);
    return result;
}

void tm_terminal_reclaim_foreground(void) {
    tm_terminal_give_foreground(getpgrp());
    tcflush(STDIN_FILENO, TCIFLUSH);
}
