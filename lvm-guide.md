# LUKS → LVM: shrink swap LV, grow root LV (Arch ISO guide)

Goal
- Reduce /dev/linux/swap from **16 GiB** → **10 GiB**
- Use the *freed space to extend* /dev/linux/root
- *Keep the existing swap* **UUID** so /etc/fstab continues to work
- You already have zram swap (6.8 GiB, PRIO 100), so disk swap becomes overflow

---------------------------------------------------------------------------
## 0) Sizing math (for sanity; commands below use extents, not guesswork)
---------------------------------------------------------------------------

Given:
- zram swap: $S_zram \approx 6.8 \text{GiB}$
- desired total swap: $\text{S_total} \approx 16.0 \text{GiB}$
- VG extent size: $E = 4 \text{MiB}$ (from `vgdisplay`)
- current disk swap $\text{LV}: 16.0 \text{GiB} (4096 \text{extents})$

Disk swap target:


$$
\begin{aligned}
S_{\text{disk}} &\approx S_{\text{total}} - S_{\text{zram}} \\
                &\approx 16.0\,\text{GiB} - 6.8\,\text{GiB} \\
                &\approx 9.2\,\text{GiB}
\end{aligned}
$$

Round to a practical value: $\text{S_disk} := 10 \text{GiB}$

Convert $10 \text{GiB} \text{to} \text{MiB}$:

$$
\begin{aligned}
10\,\text{GiB} &= 10 \cdot 1024\,\text{MiB} \\
               &= 10240\,\text{MiB}
\end{aligned}
$$

Convert to LVM extents:

$$
\begin{aligned}
\text{extents}
&= \frac{10240\,\text{MiB}}{4\,\text{MiB/extent}}
&= 2560
\end{aligned}
$$


Freed extents:

$$
\begin{aligned}
  \text{current_swap_extents} &- \text{new_swap_extents}
                              &= 4096 - 2560
                              &= 1536 \text{extents}
\end{aligned}
$$

Freed size:

$$
\begin{aligned}
  1536 \text{extents} \cdot 4 \frac{\text{MiB}}{\text{extent}} \\
  &= 6144 \text{\text{MiB}} \\
  &= 6 \text{GiB}
\end{aligned}
$$
So: shrinking swap to $10 \text{GiB}$ frees exactly $6 \text{GiB}$ for root.

---------------------------------------------------------------------------
## 1) Boot Arch ISO and become root
---------------------------------------------------------------------------

```bash
sudo -i
```
---------------------------------------------------------------------------
## 2) Unlock LUKS and activate LVM
---------------------------------------------------------------------------
```bash
cryptsetup open /dev/nvme0n1p7 cryptroot
vgscan --mknodes
vgchange -ay
```

Verify LVs exist:

```bash
lvs -o vg_name,lv_name,lv_size,lv_path
vgs
pvs
```
You should see:
- **/dev/linux/root**
- **/dev/linux/swap**
- **/dev/linux/home**

---------------------------------------------------------------------------
## 3) Backup LVM metadata (recommended safety net)
---------------------------------------------------------------------------
```bash
vgcfgbackup -f /root/vgcfgbackup-linux-$(date +%F_%H%M%S).conf linux
```
---------------------------------------------------------------------------
## 4) Ensure swap is OFF (ISO usually has none active, but be explicit)
---------------------------------------------------------------------------
```bash
swapoff -a || true
swapon --show
```
---------------------------------------------------------------------------
## 5) Shrink swap LV to 10 GiB (2560 extents)
---------------------------------------------------------------------------

# Using extents avoids any unit ambiguity.

```bash
lvreduce -y -l 2560 /dev/linux/swap
```

Confirm new size:

```bash
lvs -o lv_name,lv_size,lv_path /dev/linux/swap
```
---------------------------------------------------------------------------
## 6) Recreate swap signature with the SAME UUID from your /etc/fstab
---------------------------------------------------------------------------

Your **swap UUID** (from your fstab):
- 04e10157-9bc8-4bd2-a35b-68674bf84648

Recreate swap header:

```bash
mkswap -U 04e10157-9bc8-4bd2-a35b-68674bf84648 /dev/linux/swap
```
Verify:

```bash
blkid /dev/linux/swap
```
---------------------------------------------------------------------------
## 7) Extend root LV by all free space (the 6 GiB freed)
---------------------------------------------------------------------------
```bash
lvextend -y -l +100%FREE /dev/linux/root
```

Verify:

```bash
lvs -o lv_name,lv_size,lv_path /dev/linux/root
vgs
```
---------------------------------------------------------------------------
## 8) Check ext4 and grow filesystem to fill the enlarged LV
---------------------------------------------------------------------------

# Root is offline (unmounted) in the ISO → correct mode for e2fsck.


```bash
e2fsck -f /dev/linux/root
resize2fs /dev/linux/root
```

---------------------------------------------------------------------------
## 9) Final verification before reboot
---------------------------------------------------------------------------
```bash
lvs -o vg_name,lv_name,lv_size
blkid /dev/linux/swap
blkid /dev/linux/root
```

(Optional) If you want to mount root and glance at /etc/fstab:

```bash
mount /dev/linux/root /mnt
cat /mnt/etc/fstab
umount /mnt
```
---------------------------------------------------------------------------
## 10) Reboot into your installed system
---------------------------------------------------------------------------


```bash
reboot now
```
---------------------------------------------------------------------------
## 11) Post-boot: verify swap priorities and (optionally) set disk swap pri
---------------------------------------------------------------------------

```bash
swapon --show=NAME,TYPE,SIZE,USED,PRIO
free -h
```

Expected:
- /dev/zram0 has PRIO 100
- /dev/linux/swap has a lower priority (currently shown as -2)

To make disk-swap priority explicit and persistent, edit /etc/fstab:

Old:
  UUID=04e10157-9bc8-4bd2-a35b-68674bf84648 none swap defaults 0 0

New (example):
  UUID=04e10157-9bc8-4bd2-a35b-68674bf84648 none swap defaults,pri=10 0 0

Then:

```bash
sudo swapoff /dev/linux/swap
sudo swapon  /dev/linux/swap
swapon --show
```
---------------------------------------------------------------------------
## Hard constraint: hibernation
---------------------------------------------------------------------------

If you use suspend-to-disk (hibernation), shrinking disk swap may break resume
unless your resume device and swap sizing are configured appropriately. If you
do not hibernate, this procedure is straightforward.

