#include <ghostty/vt.h>
#include "platform.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(test) do { if (!(test)) { fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #test); exit(1); } } while (0)
static uint8_t reply[128];
static size_t reply_length;
static void write_pty(GhosttyTerminal terminal, void *userdata, const uint8_t *data, size_t length)
{
    (void)terminal; (void)userdata;
    CHECK(length<=sizeof(reply)); memcpy(reply,data,length); reply_length=length;
}

static void vt_text(GhosttyTerminal terminal, const char *text)
{
    ghostty_terminal_vt_write(terminal,(const uint8_t *)text,strlen(text));
}

static void prompt(GhosttyTerminal terminal, uint16_t columns)
{
    vt_text(terminal,"\033]133;A\007\r\n\r\n\033[A~");
    for (uint16_t x=1;x<columns;x++) vt_text(terminal,"─");
    vt_text(terminal,"\r\n> \033]133;B\007");
}

static size_t occurrences(const uint8_t *text, size_t length, const char *needle)
{
    size_t count=0,n=strlen(needle);
    for(size_t i=0;i+n<=length;i++) if(!memcmp(text+i,needle,n)) count++;
    return count;
}

static void prompt_reflow(void)
{
    GhosttyTerminal terminal=NULL; GhosttyFormatter formatter=NULL;
    CHECK(ghostty_terminal_new(NULL,&terminal,20,10)==GHOSTTY_SUCCESS);
    CHECK(ghostty_formatter_terminal_new(NULL,&formatter,terminal)==GHOSTTY_SUCCESS);
    vt_text(terminal,"keep output\r\n"); prompt(terminal,20);
    const uint16_t widths[]={12,30,16,20};
    for(int round=0;round<5;round++) for(size_t i=0;i<sizeof(widths)/sizeof(widths[0]);i++) {
        CHECK(ghostty_terminal_resize(terminal,widths[i],10,7,17)==GHOSTTY_SUCCESS);
        vt_text(terminal,"\r\033[A\033[A\033[J"); prompt(terminal,widths[i]);
        uint8_t *text=NULL; size_t length=0; uint16_t y=0;
        CHECK(ghostty_formatter_format_alloc(formatter,NULL,&text,&length)==GHOSTTY_SUCCESS);
        CHECK(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y)==GHOSTTY_SUCCESS);
        if (occurrences(text,length,"~")!=1 || occurrences(text,length,"keep output")!=1 || y!=3) {
            fprintf(stderr,"Prompt fixture contents: %.*s\n",(int)length,text);
            fprintf(stderr,"Prompt reflow round %d width %u: rulers=%lu output=%lu cursor=%u\n",round,widths[i],
                (unsigned long)occurrences(text,length,"~"),(unsigned long)occurrences(text,length,"keep output"),y);
        }
        CHECK(occurrences(text,length,"~")==1 && occurrences(text,length,"keep output")==1 && y==3);
        ghostty_free(NULL,text,length);
    }
    for(int round=0;round<5;round++) {
        CHECK(ghostty_terminal_resize(terminal,20,8,7,17)==GHOSTTY_SUCCESS);
        CHECK(ghostty_terminal_resize(terminal,12,8,7,17)==GHOSTTY_SUCCESS);
        vt_text(terminal,"\r\033[A\033[A\033[J"); prompt(terminal,12);
        uint16_t y=0;CHECK(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y)==GHOSTTY_SUCCESS);
        fprintf(stderr,"Vertical then horizontal shrink %d: cursor=%u\n",round,y);CHECK(y==3);
        CHECK(ghostty_terminal_resize(terminal,20,10,7,17)==GHOSTTY_SUCCESS);
        vt_text(terminal,"\r\033[A\033[A\033[J");prompt(terminal,20);
    }
    for(int round=0;round<5;round++) {
        for(int n=0;n<24;n++) {
            uint16_t width=12+(n*7)%20,rows=8+(n*3)%12;
            CHECK(ghostty_terminal_resize(terminal,width,rows,7,17)==GHOSTTY_SUCCESS);
        }
        CHECK(ghostty_terminal_resize(terminal,20,10,7,17)==GHOSTTY_SUCCESS);
        vt_text(terminal,"\r\033[A\033[A\033[J"); prompt(terminal,20);
        uint16_t y=0; CHECK(ghostty_terminal_get(terminal,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y)==GHOSTTY_SUCCESS);
        fprintf(stderr,"Core resize burst %d: cursor=%u\n",round,y); CHECK(y==3);
    }
    ghostty_formatter_free(formatter); ghostty_terminal_free(terminal);
    puts("Repeated full-width multiline prompt reflow preserves output without duplicate rows: PASS");
}

int main(void)
{
    imac_core_init();
    CHECK(strcmp(ghostty_version(), "1.0.0") == 0);
    printf("libghostty-vt version: %s (headers %s)\n",ghostty_version(),GHOSTTY_VT_VERSION);
    bool simd=true, kitty_graphics=true;
    CHECK(ghostty_build_info(GHOSTTY_BUILD_INFO_SIMD,&simd)==GHOSTTY_SUCCESS && !simd);
    CHECK(ghostty_build_info(GHOSTTY_BUILD_INFO_KITTY_GRAPHICS,&kitty_graphics)==GHOSTTY_SUCCESS && !kitty_graphics);
    GhosttyTerminal terminal = NULL;
    CHECK(ghostty_terminal_new(NULL, &terminal, 80, 24) == GHOSTTY_SUCCESS);
    const char *text = "Hello Snow Leopard\r\n\033[31mred\033[0m "
                       "\xc4\x81\xc4\x8d\xc4\x93 \xe4\xb8\xad\xe6\x96\x87\r\n";
    ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));
    GhosttyRenderState state = NULL;
    CHECK(ghostty_render_state_new(NULL, &state) == GHOSTTY_SUCCESS);
    CHECK(ghostty_render_state_update(state, terminal) == GHOSTTY_SUCCESS);
    uint16_t rows = 0, cols = 0;
    CHECK(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols) == GHOSTTY_SUCCESS);
    CHECK(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) == GHOSTTY_SUCCESS);
    CHECK(cols == 80 && rows == 24);
    GhosttyFormatter formatter = NULL;
    CHECK(ghostty_formatter_terminal_new(NULL, &formatter, terminal) == GHOSTTY_SUCCESS);
    uint8_t *formatted = NULL; size_t length = 0;
    CHECK(ghostty_formatter_format_alloc(formatter, NULL, &formatted, &length) == GHOSTTY_SUCCESS);
    CHECK(length >= strlen("Hello Snow Leopard"));
    CHECK(memcmp(formatted, "Hello Snow Leopard", strlen("Hello Snow Leopard")) == 0);
    printf("Formatted terminal (%lu bytes):\n%.*s\n", (unsigned long)length, (int)length, formatted);
    ghostty_free(NULL, formatted, length);
    ghostty_formatter_free(formatter);
    CHECK(ghostty_terminal_resize(terminal, 100, 30, 9, 18) == GHOSTTY_SUCCESS);
    CHECK(ghostty_render_state_update(state, terminal) == GHOSTTY_SUCCESS);
    CHECK(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols) == GHOSTTY_SUCCESS);
    CHECK(cols == 100);
    GhosttyKeyEncoder encoder = NULL; GhosttyKeyEvent event = NULL;
    CHECK(ghostty_key_encoder_new(NULL, &encoder) == GHOSTTY_SUCCESS);
    CHECK(ghostty_key_event_new(NULL, &event) == GHOSTTY_SUCCESS);
    ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS);
    ghostty_key_event_set_key(event, GHOSTTY_KEY_ARROW_UP);
    ghostty_key_encoder_set_from_terminal(encoder, terminal);
    uint8_t output[128]; size_t count = 0;
    CHECK(ghostty_key_encoder_encode(encoder, event, output, sizeof(output), &count) == GHOSTTY_SUCCESS);
    CHECK(count == 3 && memcmp(output, "\033[A", 3) == 0);
    const char *mode = "\033[?1h";
    ghostty_terminal_vt_write(terminal, (const uint8_t *)mode, strlen(mode));
    ghostty_key_encoder_set_from_terminal(encoder, terminal);
    CHECK(ghostty_key_encoder_encode(encoder, event, output, sizeof(output), &count) == GHOSTTY_SUCCESS);
    CHECK(count == 3 && memcmp(output, "\033OA", 3) == 0);
    ghostty_terminal_set(terminal,GHOSTTY_TERMINAL_OPT_WRITE_PTY,(const void *)write_pty);
    ghostty_terminal_vt_write(terminal,(const uint8_t *)"\033[6n",4);
    CHECK(reply_length==6 && memcmp(reply,"\033[3;1R",6)==0);
    char pasted[]="hello\nworld";
    CHECK(ghostty_paste_encode(pasted,strlen(pasted),true,output,sizeof(output),&count)==GHOSTTY_SUCCESS);
    CHECK(count>=12 && memcmp(output,"\033[200~",6)==0 && memcmp(output+count-6,"\033[201~",6)==0);
    CHECK(!ghostty_paste_is_safe("\033[201~",6));
    GhosttyMouseEncoder mouse=NULL; GhosttyMouseEvent mouse_event=NULL;
    CHECK(ghostty_mouse_encoder_new(NULL,&mouse)==GHOSTTY_SUCCESS);
    CHECK(ghostty_mouse_event_new(NULL,&mouse_event)==GHOSTTY_SUCCESS);
    const char *mouse_modes="\033[?1000h\033[?1006h";
    ghostty_terminal_vt_write(terminal,(const uint8_t *)mouse_modes,strlen(mouse_modes));
    ghostty_mouse_encoder_set_from_terminal(mouse,terminal);
    GhosttyMouseEncoderSize mouse_size=GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
    mouse_size.screen_width=1000; mouse_size.screen_height=600;
    mouse_size.cell_width=10; mouse_size.cell_height=20;
    ghostty_mouse_encoder_set(mouse,GHOSTTY_MOUSE_ENCODER_OPT_SIZE,&mouse_size);
    ghostty_mouse_event_set_action(mouse_event,GHOSTTY_MOUSE_ACTION_PRESS);
    ghostty_mouse_event_set_button(mouse_event,GHOSTTY_MOUSE_BUTTON_LEFT);
    ghostty_mouse_event_set_position(mouse_event,(GhosttyMousePosition){15,25});
    CHECK(ghostty_mouse_encoder_encode(mouse,mouse_event,output,sizeof(output),&count)==GHOSTTY_SUCCESS);
    CHECK(count==strlen("\033[<0;2;2M") && memcmp(output,"\033[<0;2;2M",count)==0);
    const char *styles="\033[2J\033[H\033[1;3;4;7;9mX\033[0m";
    ghostty_terminal_vt_write(terminal,(const uint8_t *)styles,strlen(styles));
    CHECK(ghostty_render_state_update(state,terminal)==GHOSTTY_SUCCESS);
    GhosttyRenderStateRowIterator rows_iterator=NULL;
    GhosttyRenderStateRowCells row_cells=NULL;
    CHECK(ghostty_render_state_row_iterator_new(NULL,&rows_iterator)==GHOSTTY_SUCCESS);
    CHECK(ghostty_render_state_row_cells_new(NULL,&row_cells)==GHOSTTY_SUCCESS);
    CHECK(ghostty_render_state_get(state,GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,&rows_iterator)==GHOSTTY_SUCCESS);
    CHECK(ghostty_render_state_row_iterator_next(rows_iterator));
    CHECK(ghostty_render_state_row_get(rows_iterator,GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,&row_cells)==GHOSTTY_SUCCESS);
    CHECK(ghostty_render_state_row_cells_next(row_cells));
    GhosttyStyle style={0};
    CHECK(ghostty_render_state_row_cells_get(row_cells,GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,&style)==GHOSTTY_SUCCESS);
    GhosttyStyleFlags expected=GHOSTTY_STYLE_FLAG_BOLD|GHOSTTY_STYLE_FLAG_ITALIC|GHOSTTY_STYLE_FLAG_INVERSE|GHOSTTY_STYLE_FLAG_STRIKETHROUGH;
    CHECK((style.flags&expected)==expected && GHOSTTY_STYLE_UNDERLINE(style)!=0);
    ghostty_render_state_row_cells_free(row_cells);
    ghostty_render_state_row_iterator_free(rows_iterator);
    ghostty_mouse_event_free(mouse_event); ghostty_mouse_encoder_free(mouse);
    ghostty_key_event_free(event); ghostty_key_encoder_free(encoder);
    ghostty_render_state_free(state); ghostty_terminal_free(terminal);
    prompt_reflow();
    puts("libghostty-vt version / features / Unicode / resize / keys / replies / paste / mouse / style flags: PASS");
    return 0;
}
