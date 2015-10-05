CC = gcc
CFLAGS = -march=native -O3 -Wall
LDFLAGS = -lm

all: c63enc c63dec c63pred

%.o: %.c
	$(CC) $< $(CFLAGS) -c -o $@

c63enc: c63enc.o dsp.o tables.o io.o c63_write.o c63.h common.o me.o
	$(CC) $^ $(CFLAGS) $(LDFLAGS) -o $@
c63dec: c63dec.c dsp.o tables.o io.o c63.h common.o me.o
	$(CC) $^ $(CFLAGS) $(LDFLAGS) -o $@
c63pred: c63dec.c dsp.o tables.o io.o c63.h common.o me.o
	$(CC) $^ -DC63_PRED $(CFLAGS) $(LDFLAGS) -o $@


encode: 
	./c63enc -w 352 -h 288 -o ./test.c63 foreman.yuv

decode:
	./c63dec ./test.c63 ./test.yuv

prof:
	gprof -b c63enc gmon.out

test: clean c63enc encode prof


vlc:
	vlc --rawvid-width 352 --rawvid-height 288 --rawvid-chroma I420 ./test.yuv


clean:
	rm -f *.o c63enc c63dec c63pred
