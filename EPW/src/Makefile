# Makefile for EPW

include make.sys
include make.libs

#
# use recursive definitions in Makefile to modify the PATH for modules
#

DBGFLAGS   = -g -traceback -fp-stack-check
IFLAGS   = -I../../include  
MODFLAGS = -I./ -I../../Modules -I../../iotk/src \
           -I../../PW -I../../PH -I../../PP
LIBOBJS  = ../../flib/ptools.a ../../flib/flib.a \
           ../../clib/clib.a ../../iotk/src/libiotk.a

W90LIB   = ../../W90/libwannier.a

EPWOBJS = \
a2f.o \
allocate_epwq.o \
bcast_epw_input.o \
close_epw.o \
createkmap.o \
dasmio.o \
deallocate_epw.o \
dmebloch2wan.o \
dmewan2bloch.o \
dvanqq2.o \
dvqpsi_us3.o \
dvqpsi_us_only3.o \
dynbloch2wan.o \
dynwan2bloch.o \
elphel2_shuffle.o \
elph.o \
elphon_shuffle.o \
elphon_shuffle_wrap.o \
elphsum3.o \
elphsum3_strict.o \
ephbloch2wane.o \
ephbloch2wanp.o \
ephwan2bloch.o \
ephwan2blochp.o \
ephwann_shuffle.o \
epwcom.o \
epw_init.o \
epw.o \
epw_readin.o \
epw_setup.o \
epw_summary.o \
fermiwindow.o \
gmap_sym.o \
hambloch2wan.o \
hamwan2bloch.o \
kfold.o \
kpointdivision.o \
ktokpmq.o \
loadmesh.o \
loadumat.o \
nesting_fn.o \
openfilepw.o \
plot_band.o \
poolgather.o \
print_clock_epw.o \
pw2wan90epw.o \
readdvscf.o \
readgmap.o \
readigk.o \
readmat_shuffle.o \
readwfc.o \
refold.o \
reset_sym.o \
rotate_eigenm.o \
rotate_epmat.o \
rwepmatw.o \
selfen_elec.o \
selfen_phon.o \
selfen_phon_tet.o \
set_ndnmbr.o \
setphases.o \
setphases_wrap.o \
sort.o \
spectral_func.o \
star_q2.o \
stop_epw.o \
tetrahedron.o \
vmebloch2wan.o \
vmewan2bloch.o \
wannierize.o \
wigner_seitz2.o \
wigner_seitz.o \
write_ephmat.o

default : epw

all : epw

epw : pw ph wannier $(EPWOBJS) $(LIBOBJS)
	$(LD) -o epw.x $(MODULES) $(PWOBJS) $(PHOBJS) \
	$(EPWOBJS) $(W90LIB) $(LDFLAGS) $(DBGFLAGS) $(LIBOBJS) $(LIBS)
	- ( cd ../bin ; ln -fs ../src/epw.x . )

pw : 
	cd ../../PW ; make

ph : 
	cd ../../PH ; make

wannier :
	cd ../../W90 ; make libs

#added by schuberm
tetra : 
	mpif90 -O2 -assume byterecl -nomodule -fpp -D__INTEL -D__FFTW -D__MPI -D__PARA -I../../include   -I./ -I../../Modules -I../../iotk/src -I../../PW -I../../PH -I../../PP -c selfen_elec_tetra.f90

clean :
	- /bin/rm -f  *.o *~ *.F90 *.d *.mod *.i 

include make.depend
