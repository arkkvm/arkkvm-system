#include "lvgl/lvgl.h"
#include "lv_drivers/display/fbdev.h"
#include "lv_drivers/indev/evdev.h"
#include <unistd.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <arpa/inet.h>
#include <sys/ioctl.h>
#include <net/if.h>

#define SCREEN_WIDTH 240
#define SCREEN_HEIGHT 300

static lv_obj_t *label;
static char g_target[128] = "www.baidu.com";  // 默认目标

// ==================== LVGL Tick ====================
uint32_t custom_tick_get(void)
{
    static uint64_t start_ms = 0;
    if(start_ms == 0) {
        struct timeval tv_start;
        gettimeofday(&tv_start, NULL);
        start_ms = (tv_start.tv_sec*1000000 + tv_start.tv_usec)/1000;
    }
    struct timeval tv_now;
    gettimeofday(&tv_now, NULL);
    uint64_t now_ms = (tv_now.tv_sec*1000000 + tv_now.tv_usec)/1000;
    return (uint32_t)(now_ms - start_ms);
}

// ==================== 获取 IP ====================
static void get_ip_addr(const char *iface, char *ip, size_t len) {
    int fd;
    struct ifreq ifr;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if(fd < 0) {
        strncpy(ip, "No IP", len);
        return;
    }
    ifr.ifr_addr.sa_family = AF_INET;
    strncpy(ifr.ifr_name, iface, IFNAMSIZ-1);
    if(ioctl(fd, SIOCGIFADDR, &ifr) == 0) {
        snprintf(ip, len, "%s", inet_ntoa(((struct sockaddr_in *)&ifr.ifr_addr)->sin_addr));
    } else {
        strncpy(ip, "No IP", len);
    }
    close(fd);
}

// ==================== Ping ====================
int ping_host(const char *host) {
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "ping -c 1 -W 1 %s > /tmp/ping_result.txt 2>&1", host);
    return system(cmd) == 0;
}

void get_ping_output(char *buf, size_t size) {
    FILE *fp = fopen("/tmp/ping_result.txt","r");
    if(!fp){ snprintf(buf,size,"Cannot open ping result"); return; }
    char line[256];
    buf[0]=0;
    while(fgets(line,sizeof(line),fp)) {
        if(strstr(line,"bytes from")) {
            strncpy(buf,line,size-1);
            buf[size-1]=0;
            break;
        }
    }
    fclose(fp);
}

// ==================== Ping 线程 ====================
void *update_task(void *arg){
    char buf[512];
    int fail_count = 0;

    // === 先等待 IP 地址 ===
    char ip[64];
    int wait_time = 0;
    while(1) {
        get_ip_addr("eth0", ip, sizeof(ip));
        if(strcmp(ip, "No IP") != 0) {
            break;  // 有 IP，跳出等待
        }
        if(wait_time >= 20000) {
            // 10 秒超时，算失败
            snprintf(buf, sizeof(buf), "eth0 IP: No IP\n[ERROR] Get IP timeout (20s)");
            lv_label_set_text(label, buf);
            lv_obj_set_style_text_color(label, lv_palette_main(LV_PALETTE_RED), 0);
            lv_timer_handler();
            return NULL;  // 退出线程
        }
        snprintf(buf, sizeof(buf), "Waiting for eth0 IP... %d s", wait_time/1000);
        lv_label_set_text(label, buf);
        lv_obj_set_style_text_color(label, lv_palette_main(LV_PALETTE_ORANGE), 0);
        lv_timer_handler();
        usleep(500*1000);
        wait_time += 500;
    }

    // === 正常 ping 测试逻辑 ===
    while(1){
        int success = ping_host(g_target);
        char ping_out[256] = {0};
        get_ping_output(ping_out,sizeof(ping_out));

        if(success){
            fail_count = 0;
            snprintf(buf,sizeof(buf),"eth0 IP: %s\n%s", ip, ping_out);
            lv_label_set_text(label, buf);
            lv_obj_set_style_text_color(label, lv_palette_main(LV_PALETTE_GREEN), 0);
            lv_timer_handler();
            usleep(500*1000);
        } else {
            fail_count++;
            if(fail_count >= 3) {
                // 连续三次失败 -> 显示完整结果并退出
                FILE *fp = fopen("/tmp/ping_result.txt","r");
                if(fp) { fread(buf,1,sizeof(buf)-1,fp); buf[sizeof(buf)-1]=0; fclose(fp); }
                else strcpy(buf,"Ping failed, cannot read file");
                char final[600];
                snprintf(final,sizeof(final),"eth0 IP: %s\n%s", ip, buf);
                lv_label_set_text(label, final);
                lv_obj_set_style_text_color(label, lv_palette_main(LV_PALETTE_RED), 0);
                lv_timer_handler();
                break;
            } else {
                snprintf(buf,sizeof(buf),"eth0 IP: %s\nPing %s failed (%d/3)", ip, g_target, fail_count);
                lv_label_set_text(label, buf);
                lv_obj_set_style_text_color(label, lv_palette_main(LV_PALETTE_ORANGE), 0);
                lv_timer_handler();
                usleep(500*1000);
            }
        }
    }
    return NULL;
}

// ==================== 随机触摸点 ====================
#define DOT_NUM 5
#define DOT_SIZE 40
static lv_obj_t *dots[DOT_NUM];

static void dot_timer_cb(lv_timer_t * t){
    lv_obj_t *dot = (lv_obj_t*)t->user_data;
    lv_obj_del(dot);
    lv_timer_del(t);
}

static void dot_event_cb(lv_event_t * e) {
    lv_obj_t * dot = lv_event_get_target(e);
    lv_obj_del(dot);   // 点击后立即消失
}

static void create_random_dots(void){
    int positions[DOT_NUM][2] = {0};
    int count=0;
    while(count<DOT_NUM){
        int x = rand()%(SCREEN_WIDTH-DOT_SIZE);
        int y = rand()%(SCREEN_HEIGHT-DOT_SIZE);
        int duplicate=0;
        for(int i=0;i<count;i++){
            if(abs(positions[i][0]-x)<DOT_SIZE && abs(positions[i][1]-y)<DOT_SIZE){
                duplicate=1; break;
            }
        }
        if(duplicate) continue;
        positions[count][0]=x;
        positions[count][1]=y;
        lv_obj_t *dot = lv_obj_create(lv_scr_act());
        lv_obj_set_size(dot,DOT_SIZE,DOT_SIZE);
        lv_obj_set_style_radius(dot, LV_RADIUS_CIRCLE,0);
        lv_obj_set_style_bg_color(dot, lv_palette_main(LV_PALETTE_RED),0);
        lv_obj_add_event_cb(dot, dot_event_cb, LV_EVENT_CLICKED, NULL);
        lv_obj_align(dot, LV_ALIGN_TOP_LEFT, x, y);
        dots[count]=dot;
        count++;
    }
}

// ==================== 主函数 ====================
int main(int argc, char **argv){
    srand(time(NULL));

    if(argc > 1) {
        strncpy(g_target, argv[1], sizeof(g_target)-1);
        g_target[sizeof(g_target)-1]=0;
    }

    lv_init();
    fbdev_init();

    static lv_color_t buf[128*1024];
    static lv_disp_draw_buf_t draw_buf;
    lv_disp_draw_buf_init(&draw_buf, buf, NULL, 128*1024);

    static lv_disp_drv_t disp_drv;
    lv_disp_drv_init(&disp_drv);
    disp_drv.draw_buf = &draw_buf;
    disp_drv.flush_cb = fbdev_flush;
    disp_drv.hor_res = SCREEN_WIDTH;
    disp_drv.ver_res = SCREEN_HEIGHT;
    lv_disp_drv_register(&disp_drv);

    evdev_init();
    static lv_indev_drv_t indev_drv;
    lv_indev_drv_init(&indev_drv);
    indev_drv.type = LV_INDEV_TYPE_POINTER;
    indev_drv.read_cb = evdev_read;
    lv_indev_drv_register(&indev_drv);

    // 创建 label
    label = lv_label_create(lv_scr_act());
    lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(label, SCREEN_WIDTH-20);
    lv_label_set_text(label, "Initializing...");
    lv_obj_set_style_text_font(label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(label, LV_ALIGN_CENTER,0,0);

    // 启动 ping 线程
    pthread_t tid;
    pthread_create(&tid,NULL,update_task,NULL);

    // 创建随机触摸点
    create_random_dots();

    // 主循环
    while(1){
        lv_timer_handler();
        usleep(5000);
    }
}
