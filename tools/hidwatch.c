// hidwatch — live dump of Parblo A610 reports.
// Listens on TWO pen interfaces: 0 (Digitizer 0x0D/0x02) and 1 (Mouse 0x01/0x02).
// The keyboard interface (0x01/0x06) is not opened on purpose.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VID 0x5543
#define PID 0x0081

static uint8_t  gBuf[64];
static uint64_t gN7 = 0, gN10 = 0, gN1 = 0, gNx = 0;
static double   gT0 = 0;
static int      gQuiet = 0;

static double now_s(void){ return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC)/1e9; }

static void put(CFMutableDictionaryRef d, const char *k, int v){
    CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, k, kCFStringEncodingUTF8);
    CFDictionarySetValue(d, s, n); CFRelease(n); CFRelease(s);
}
static CFMutableDictionaryRef match(int page, int usage){
    CFMutableDictionaryRef m = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    put(m, kIOHIDVendorIDKey, VID);  put(m, kIOHIDProductIDKey, PID);
    put(m, kIOHIDPrimaryUsagePageKey, page); put(m, kIOHIDPrimaryUsageKey, usage);
    return m;
}
static void flags(uint8_t f){
    printf("%c%c%c%c%c%c%c",
        (f&0x01)?'T':'.', (f&0x02)?'B':'.', (f&0x04)?'E':'.', (f&0x08)?'I':'.',
        (f&0x10)?'s':'.', (f&0x20)?'b':'.', (f&0x40)?'R':'.');
}
static void bar(double frac){
    int n=(int)(frac*22.0+0.5); printf("  ");
    for(int i=0;i<22;i++) putchar(i<n?'#':(i==0?'.':' '));
}

static void onReport(void *ctx, IOReturn res, void *sender, IOHIDReportType type,
                     uint32_t rid, uint8_t *rep, CFIndex len){
    (void)ctx;(void)res;(void)sender;(void)type;
    if(len<=0) return;
    uint8_t *p=rep; CFIndex n=len;
    if(n>0 && p[0]==(uint8_t)rid){ p++; n--; }
    double t=now_s()-gT0;

    if(rid==7 && n>=7){                     // IF0: pen, full resolution
        gN7++;
        uint16_t x=p[1]|(p[2]<<8), y=p[3]|(p[4]<<8), pr=p[5]|(p[6]<<8);
        if(gQuiet && (gN7%10)) return;
        printf("%7.3f IF0 ID7  ",t); flags(p[0]);
        printf("  X=%5u Y=%5u  P=%4u  pressure %5.3f",x,y,pr,pr/2047.0);
        bar(pr/2047.0); printf("\n");
    } else if(rid==10 && n>=7){             // IF1: pen, cut down resolution
        gN10++;
        uint16_t x=p[1]|(p[2]<<8), y=p[3]|(p[4]<<8), pr=p[5]|(p[6]<<8);
        if(gQuiet && (gN10%10)) return;
        printf("%7.3f IF1 ID10 ",t); flags(p[0]);
        printf("  X=%5u Y=%5u  P=%4u  pressure %5.3f",x,y,pr,pr/2047.0);
        bar(pr/2047.0); printf("\n");
    } else if(rid==1 && n>=7){              // IF1: relative mouse
        gN1++;
        int16_t dx=(int16_t)(p[1]|(p[2]<<8)), dy=(int16_t)(p[3]|(p[4]<<8));
        if(gQuiet && (gN1%10)) return;
        printf("%7.3f IF1 ID1  mouse  buttons=%02X  dX=%+6d dY=%+6d  wheel=%+d\n",
               t,p[0]&0x1F,dx,dy,(int8_t)p[5]);
    } else {
        gNx++;
        printf("%7.3f  ??? ID%-3u len=%ld:",t,rid,(long)len);
        for(CFIndex i=0;i<len && i<12;i++) printf(" %02X",rep[i]);
        printf("\n");
    }
    fflush(stdout);
}

int main(int argc,char**argv){
    double secs = (argc>1)?atof(argv[1]):20.0;
    gQuiet = (argc>2 && strcmp(argv[2],"--quiet")==0);

    if(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)!=kIOHIDAccessTypeGranted){
        printf("No Input Monitoring permission.\n"); return 1;
    }
    IOHIDManagerRef mgr=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef m0=match(0x0D,0x02), m1=match(0x01,0x02);
    const void *ms[2]={m0,m1};
    CFArrayRef arr=CFArrayCreate(kCFAllocatorDefault,ms,2,&kCFTypeArrayCallBacks);
    IOHIDManagerSetDeviceMatchingMultiple(mgr,arr);
    CFRelease(arr); CFRelease(m0); CFRelease(m1);

    if(IOHIDManagerOpen(mgr,kIOHIDOptionsTypeNone)!=kIOReturnSuccess){
        printf("IOHIDManagerOpen failed\n"); return 1; }

    CFSetRef devs=IOHIDManagerCopyDevices(mgr);
    CFIndex nd=devs?CFSetGetCount(devs):0;
    printf("Pen interfaces opened: %ld\n",(long)nd);
    if(nd){
        IOHIDDeviceRef d[8]; CFSetGetValues(devs,(const void**)d);
        for(CFIndex i=0;i<nd&&i<8;i++){
            int pg=0,us=0; CFNumberRef a;
            if((a=IOHIDDeviceGetProperty(d[i],CFSTR(kIOHIDPrimaryUsagePageKey)))) CFNumberGetValue(a,kCFNumberIntType,&pg);
            if((a=IOHIDDeviceGetProperty(d[i],CFSTR(kIOHIDPrimaryUsageKey))))     CFNumberGetValue(a,kCFNumberIntType,&us);
            printf("   usagePage=0x%02X usage=0x%02X  → %s\n",pg,us,
                   (pg==0x0D)?"INTERFACE 0 (Digitizer)":"INTERFACE 1 (Mouse)");
            IOHIDDeviceOpen(d[i],kIOHIDOptionsTypeNone);
            IOHIDDeviceRegisterInputReportCallback(d[i],gBuf,sizeof(gBuf),onReport,NULL);
        }
        CFRelease(devs);
    }
    IOHIDManagerScheduleWithRunLoop(mgr,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
    printf("\n>>> USE THE PEN NOW <<<\n\n");
    gT0=now_s();
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,secs,false);

    printf("\n--- over %.0f s ---\n",secs);
    printf("  IF0 ID7  (pen, 40000x24000)  : %llu\n",gN7);
    printf("  IF1 ID10 (pen, 2048x2048)    : %llu\n",gN10);
    printf("  IF1 ID1  (relative mouse)    : %llu\n",gN1);
    printf("  other                        : %llu\n",gNx);
    return 0;
}
