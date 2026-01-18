#pragma once

#define CURRENT_YEAR 2025

static int century_register = 0x00;

extern unsigned char second;
extern unsigned char minute;
extern unsigned char hour;
extern unsigned char day;
extern unsigned char month;
extern unsigned int year;

int get_update_in_progress_flag();

unsigned char get_RTC_register(int reg);
void read_rtc();

