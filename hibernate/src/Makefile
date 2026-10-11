# SPDX-License-Identifier: GPL-2.0
obj-m += mei-vsc.o
mei-vsc-y := platform-vsc.o

# El transporte vive en su propio módulo (mei-vsc-hw), igual que in-tree.
# Hasta v1.20 no se construía y vsc-tp.c estaba aquí solo de referencia: el
# código que corría era el de serie, así que los cambios al transporte no
# tenían ningún efecto. Ahora se compila, porque la puerta de suspensión de
# vsc_tp va aquí dentro.
obj-m += mei-vsc-hw.o
mei-vsc-hw-y := vsc-tp.o
mei-vsc-hw-y += vsc-fw-loader.o

ccflags-y += -I$(src)
