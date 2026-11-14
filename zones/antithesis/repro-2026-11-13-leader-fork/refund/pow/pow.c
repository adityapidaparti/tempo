// Mine salt s.t. keccak256(abi.encodePacked(addr, salt))[0..4]==0 (TIP-1022 registerVirtualMaster PoW)
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
static const uint64_t RC[24]={0x0000000000000001ULL,0x0000000000008082ULL,0x800000000000808aULL,0x8000000080008000ULL,0x000000000000808bULL,0x0000000080000001ULL,0x8000000080008081ULL,0x8000000000008009ULL,0x000000000000008aULL,0x0000000000000088ULL,0x0000000080008009ULL,0x000000008000000aULL,0x000000008000808bULL,0x800000000000008bULL,0x8000000000008089ULL,0x8000000000008003ULL,0x8000000000008002ULL,0x8000000000000080ULL,0x000000000000800aULL,0x800000008000000aULL,0x8000000080008081ULL,0x8000000000008080ULL,0x0000000080000001ULL,0x8000000080008008ULL};
static const int R[24]={1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44};
static const int PI[24]={10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1};
#define ROL(x,s) (((x)<<(s))|((x)>>(64-(s))))
static void kf(uint64_t s[25]){for(int r=0;r<24;r++){uint64_t b[5];for(int i=0;i<5;i++)b[i]=s[i]^s[i+5]^s[i+10]^s[i+15]^s[i+20];for(int i=0;i<5;i++){uint64_t t=b[(i+4)%5]^ROL(b[(i+1)%5],1);for(int j=0;j<25;j+=5)s[j+i]^=t;}uint64_t t=s[1];for(int i=0;i<24;i++){int j=PI[i];uint64_t u=s[j];s[j]=ROL(t,R[i]);t=u;}for(int j=0;j<25;j+=5){uint64_t c[5];for(int i=0;i<5;i++)c[i]=s[j+i];for(int i=0;i<5;i++)s[j+i]^=(~c[(i+1)%5])&c[(i+2)%5];}s[0]^=RC[r];}}
static uint8_t addr[20]; static volatile int found=0; static int NT;
static void *work(void *arg){long id=(long)arg;uint8_t m[136];for(uint64_t n=id;!found;n+=NT){memset(m,0,136);memcpy(m,addr,20);for(int i=0;i<8;i++)m[52-1-i]=(n>>(8*i))&0xff;m[52]=0x01;m[135]|=0x80;uint64_t s[25]={0};for(int i=0;i<17;i++){uint64_t w=0;for(int k=0;k<8;k++)w|=(uint64_t)m[i*8+k]<<(8*k);s[i]^=w;}kf(s);if((s[0]&MASK)==0){found=1;printf("salt=0x%064llx masterId=0x%02x%02x%02x%02x\n",(unsigned long long)n,(unsigned)((s[0]>>32)&0xff),(unsigned)((s[0]>>40)&0xff),(unsigned)((s[0]>>48)&0xff),(unsigned)((s[0]>>56)&0xff));fflush(stdout);}}return 0;}
int main(int c,char**v){const char*h=v[1]+2;for(int i=0;i<20;i++)sscanf(h+2*i,"%2hhx",&addr[i]);NT=atoi(v[2]);pthread_t t[64];for(long i=0;i<NT;i++)pthread_create(&t[i],0,work,(void*)i);for(int i=0;i<NT;i++)pthread_join(t[i],0);}
