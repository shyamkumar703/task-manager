#ifndef TASK_MANAGER_LOCAL_SUPPORT_H
#define TASK_MANAGER_LOCAL_SUPPORT_H
int tm_lock_acquire(const char *path);
int tm_lock_held(const char *path);
void tm_lock_release(int fd);
int tm_terminal_open(void);
void tm_terminal_close(void);
void tm_terminal_reclaim_foreground(void);
int tm_terminal_give_foreground(int process_group);
void tm_terminal_clear(void);
void tm_terminal_refresh(void);
int tm_terminal_rows(void);
int tm_terminal_columns(void);
int tm_terminal_key(void);
void tm_terminal_draw(int row, int col, const char *text, int width, int emphasis);
int tm_key_up(void);
int tm_key_down(void);
int tm_key_left(void);
int tm_key_right(void);
int tm_key_page_up(void);
int tm_key_page_down(void);
int tm_key_backspace(void);
int tm_key_resize(void);
#endif
