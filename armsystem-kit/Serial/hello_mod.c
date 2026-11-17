// SPDX-License-Identifier: GPL-2.0
/* Minimal kernel module. Build with the KERNEL compiler (see README):
 *   make -C "$ARMSYSTEM_KDIR" M="$PWD" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- modules */
#include <linux/init.h>
#include <linux/module.h>
#include <linux/moduleparam.h>

static int value = 1;
module_param(value, int, 0444);

static int __init hello_mod_init(void)
{
	pr_info("hello_mod: loaded value=%d\n", value);
	return 0;
}

static void __exit hello_mod_exit(void)
{
	pr_info("hello_mod: unloaded\n");
}

module_init(hello_mod_init);
module_exit(hello_mod_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("armsystem kit example module");
