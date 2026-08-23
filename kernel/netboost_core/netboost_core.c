// SPDX-License-Identifier: GPL-2.0-only
/*
 * netboost_core.c - Xiaomi 14 kernel-level network acceleration core
 *
 * Management core of the NetBoost project. Works together with tcp_bbr3.ko
 * (BBRv3 backport) to provide scenario-aware TCP congestion control on
 * Xiaomi 14 (SM8650 / android14-6.1 GKI kernel).
 *
 * IMPORTANT: GKI android14-6.1 does NOT export tcp_set_default_congestion_
 * control / tcp_get_default_congestion_control / tcp_get_allowed_congestion_
 * control to modules. Therefore this module switches algorithms through the
 * standard sysctl interface (/proc/sys/net/ipv4/tcp_congestion_control),
 * which is writable from kernel context via the proc filesystem.
 *
 * Scenario presets (based on research of Chinese mobile network usage):
 *   train    - high-speed rail / metro: frequent base-station handover,
 *              RTT spikes, throughput collapse -> BBRv3 (model-based,
 *              fast recovery, does not depend on loss signals)
 *   crowd    - concerts / dense crowds: base-station overload, bandwidth
 *              squeezed, heavy congestion -> CUBIC (loss-driven, fair,
 *              does not aggressively grab bandwidth from other users)
 *   weak     - weak signal (bathroom etc.): high random loss, low BW,
 *              RTT jitter -> westwood (bandwidth-estimation based,
 *              designed for wireless random loss)
 *   wifi     - home Wi-Fi: bufferbloat, multi-device, latency jitter
 *              -> BBRv3 + fq qdisc (low queueing delay)
 *
 * Interface:
 *   cat /proc/netboost                      # status
 *   echo "scenario=train" > /proc/netboost  # apply a scenario preset
 *   echo "algo=bbr3" > /proc/netboost       # manual algorithm switch
 *
 * Compatible with mainline 5.15 ~ 6.6 (verified against 5.15 and GKI
 * android14-6.1).
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/utsname.h>
#include <linux/version.h>
#include <linux/string.h>
#include <net/tcp.h>

#define NETBOOST_VERSION	"2.4.0"
#define NETBOOST_PROC_NAME	"netboost"
#define NETBOOST_SYSCTL_ALGO	"/proc/sys/net/ipv4/tcp_congestion_control"
/* NOTE: reading tcp_congestion_control returns only the CURRENT default;
 * the list of registered algorithms lives in tcp_available_congestion_control.
 */
#define NETBOOST_SYSCTL_AVAIL	"/proc/sys/net/ipv4/tcp_available_congestion_control"
#define NETBOOST_SYSCTL_QDISC	"/proc/sys/net/core/default_qdisc"

static struct proc_dir_entry *netboost_proc_entry;

/* ------------------------------------------------------------------ */
/* sysctl helpers (GKI does not export tcp_set_default_* to modules)  */
/* ------------------------------------------------------------------ */

static int read_sysctl_file(const char *path, char *buf, size_t len)
{
	struct file *f;
	ssize_t n;
	int ret = -EIO;

	f = filp_open(path, O_RDONLY, 0);
	if (IS_ERR(f))
		return PTR_ERR(f);

	n = kernel_read(f, buf, len - 1, &f->f_pos);
	if (n > 0) {
		buf[n] = '\0';
		strscpy(buf, strstrip(buf), len);
		ret = 0;
	}
	filp_close(f, NULL);
	return ret;
}

static int write_sysctl_file(const char *path, const char *value)
{
	struct file *f;
	ssize_t n;
	int ret = -EIO;

	f = filp_open(path, O_WRONLY, 0);
	if (IS_ERR(f))
		return PTR_ERR(f);

	n = kernel_write(f, value, strlen(value), &f->f_pos);
	if (n == (ssize_t)strlen(value))
		ret = 0;
	filp_close(f, NULL);
	return ret;
}

static int read_sysctl_algo(char *buf, size_t len)
{
	return read_sysctl_file(NETBOOST_SYSCTL_ALGO, buf, len);
}

static int write_sysctl_algo(const char *name)
{
	return write_sysctl_file(NETBOOST_SYSCTL_ALGO, name);
}

static bool algo_available(const char *name)
{
	char buf[256] = { 0 };
	char *p;

	if (read_sysctl_file(NETBOOST_SYSCTL_AVAIL, buf, sizeof(buf)) != 0)
		return false;

	/* available algorithms are space-separated in the sysctl */
	p = strstr(buf, name);
	if (!p)
		return false;
	/* ensure it is a whole token */
	if (p > buf && p[-1] != ' ')
		return false;
	if (p[strlen(name)] != '\0' && p[strlen(name)] != ' ')
		return false;
	return true;
}

static void set_default_algo(const char *name)
{
	if (write_sysctl_algo(name) == 0)
		pr_info("netboost: default congestion control set to %s\n", name);
	else
		pr_warn("netboost: failed to set %s as default\n", name);
}

static void set_default_qdisc(const char *qdisc)
{
	/* only affects interfaces created AFTER this write; live interfaces
	 * keep their current qdisc until the network is re-attached. */
	if (write_sysctl_file(NETBOOST_SYSCTL_QDISC, qdisc) == 0)
		pr_info("netboost: default qdisc set to %s\n", qdisc);
	else
		pr_warn("netboost: failed to set default qdisc %s\n", qdisc);
}

static void get_current_algo(char *buf, size_t len)
{
	if (read_sysctl_algo(buf, len) != 0)
		strscpy(buf, "unknown", len);
}

/* ------------------------------------------------------------------ */
/* scenario presets                                                   */
/* ------------------------------------------------------------------ */

struct netboost_scenario {
	const char *name;
	const char *algo;
	const char *qdisc;
	const char *desc;
};

static const struct netboost_scenario scenarios[] = {
	{ "boost", "bbr3",     "fq",
	  "all-round default for CN mobile networks: BBRv3 + fq" },
	{ "train", "bbr3",     "fq",
	  "high-speed rail/metro: BBRv3 for handover recovery" },
	{ "crowd", "cubic",    "fq_codel",
	  "concerts/dense crowds: CUBIC for fairness under overload" },
	{ "weak",  "westwood", "fq_codel",
	  "weak signal: westwood for wireless random loss" },
	{ "wifi",  "bbr3",     "fq",
	  "home Wi-Fi: BBRv3 + fq for low bufferbloat latency" },
	{ "game",  "bbr3",     "fq",
	  "game login/latency: BBRv3 + keepalive + big buffers (sysctl part in service.sh)" },
};

static int apply_scenario(const char *name)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(scenarios); i++) {
		if (strcmp(scenarios[i].name, name) == 0) {
			if (algo_available(scenarios[i].algo))
				set_default_algo(scenarios[i].algo);
			else
				pr_warn("netboost: %s not available, keeping current\n",
					scenarios[i].algo);
			set_default_qdisc(scenarios[i].qdisc);
			pr_info("netboost: scenario '%s' applied (%s)\n",
				name, scenarios[i].desc);
			return 0;
		}
	}
	return -EINVAL;
}

/* ------------------------------------------------------------------ */
/* /proc/netboost read                                                */
/* ------------------------------------------------------------------ */

static int netboost_show(struct seq_file *m, void *v)
{
	char cur[64] = { 0 };
	char avail[256] = { 0 };
	int i;

	get_current_algo(cur, sizeof(cur));
	read_sysctl_file(NETBOOST_SYSCTL_AVAIL, avail, sizeof(avail));

	seq_printf(m, "NetBoost v%s (Xiaomi 14 kernel network accelerator)\n",
		   NETBOOST_VERSION);
	seq_printf(m, "current_algo:   %s\n", cur);
	seq_printf(m, "available_algo: %s\n", avail);
	seq_printf(m, "kernel:         %s\n", init_utsname()->release);
	seq_puts(m, "scenarios:\n");
	for (i = 0; i < ARRAY_SIZE(scenarios); i++)
		seq_printf(m, "  %-6s -> %-8s (%s)\n",
			   scenarios[i].name, scenarios[i].algo,
			   scenarios[i].desc);
	seq_puts(m, "usage:\n");
	seq_printf(m, "  echo \"scenario=<boost|train|crowd|weak|wifi|game>\" > %s\n",
		   NETBOOST_PROC_NAME);
	seq_printf(m, "  echo \"algo=<name>\" > %s\n", NETBOOST_PROC_NAME);
	return 0;
}

static int netboost_open(struct inode *inode, struct file *file)
{
	return single_open(file, netboost_show, NULL);
}

/* ------------------------------------------------------------------ */
/* /proc/netboost write                                               */
/* ------------------------------------------------------------------ */

static ssize_t netboost_write(struct file *file, const char __user *ubuf,
			      size_t count, loff_t *ppos)
{
	char buf[64];
	char *cmd, *val;

	if (count >= sizeof(buf))
		count = sizeof(buf) - 1;

	if (copy_from_user(buf, ubuf, count))
		return -EFAULT;
	buf[count] = '\0';

	/* strip trailing newline */
	cmd = strstrip(buf);

	if (strncmp(cmd, "scenario=", 9) == 0) {
		val = cmd + 9;
		if (apply_scenario(val) == 0)
			return count;
		pr_warn("netboost: unknown scenario '%s'\n", val);
		return -EINVAL;
	}

	if (strncmp(cmd, "algo=", 5) == 0) {
		val = cmd + 5;
		if (strlen(val) == 0 || strlen(val) >= TCP_CA_NAME_MAX)
			return -EINVAL;
		if (!algo_available(val)) {
			pr_warn("netboost: algorithm %s not available\n", val);
			return -EINVAL;
		}
		set_default_algo(val);
		return count;
	}

	if (strcmp(cmd, "status") == 0)
		return count;

	pr_warn("netboost: unknown command '%s'\n", cmd);
	return -EINVAL;
}

static const struct proc_ops netboost_proc_ops = {
	.proc_open	= netboost_open,
	.proc_read	= seq_read,
	.proc_write	= netboost_write,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
};

/* ------------------------------------------------------------------ */
/* module lifecycle                                                   */
/* ------------------------------------------------------------------ */

static int __init netboost_init(void)
{
	char cur[64] = { 0 };

	get_current_algo(cur, sizeof(cur));
	pr_info("netboost: loaded (v%s), current algo was %s\n",
		NETBOOST_VERSION, cur);

	/* prefer BBRv3, fall back to BBRv1, then to cubic */
	if (algo_available("bbr3"))
		set_default_algo("bbr3");
	else if (algo_available("bbr"))
		set_default_algo("bbr");
	else if (algo_available("cubic"))
		set_default_algo("cubic");

	netboost_proc_entry = proc_create(NETBOOST_PROC_NAME, 0644, NULL,
					  &netboost_proc_ops);
	if (!netboost_proc_entry) {
		pr_err("netboost: failed to create /proc/%s\n",
		       NETBOOST_PROC_NAME);
		return -ENOMEM;
	}

	return 0;
}

static void __exit netboost_exit(void)
{
	remove_proc_entry(NETBOOST_PROC_NAME, NULL);
	pr_info("netboost: unloaded\n");
}

module_init(netboost_init);
module_exit(netboost_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Te-River");
MODULE_DESCRIPTION("Xiaomi 14 kernel-level network acceleration core (scenario-aware)");
MODULE_VERSION(NETBOOST_VERSION);
