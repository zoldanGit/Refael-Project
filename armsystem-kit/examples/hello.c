/* Minimal user program: build with the SDK compiler (see README, compiler rule).
 *   arm-linux-gcc -g -o hello hello.c */
#include <stdio.h>

int main(void)
{
	int answer = 42;

	printf("hello from ARMv7, answer=%d\n", answer);
	return 0;
}
