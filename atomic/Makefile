#
# Makefile for atomic code
#

include ../make.sys

LD1OBJS = \
add_exchange.o \
all_electron.o \
ascheq.o \
ascheqps.o \
ascheqps_old.o \
ascheqps_drv.o \
c6_dft.o \
c6_tfvw.o \
calculate_gipaw_orbitals.o \
cfdsol.o \
chargeps.o \
compute_chi.o \
compute_chi_tm.o \
compute_det.o \
compute_phi.o \
compute_phi_tm.o \
compute_phius.o \
compute_potps.o \
compute_potps_new.o \
compute_q_3bess.o \
compute_solution.o \
descreening.o \
dfx_new.o \
dir_outward.o \
dirsol.o \
dmixp.o \
drhoofv.o \
drho0ofvx.o \
dvex.o \
el_config.o \
elsd.o \
elsd_highv.o \
elsdps.o \
elsdps_paw.o \
esic.o \
export_upf.o \
find_qi.o \
gener_pseudo.o \
green.o \
import_upf.o \
int_0_inf_dr.o \
integrate_inward.o \
integrate_outward.o \
inward.o \
outward.o \
intref.o \
ld1_readin.o \
ld1_setup.o \
ld1_writeout.o \
lderiv.o \
lderivps.o \
lschps.o \
newd_at.o \
new_potential.o \
nodenum.o \
normalize.o \
occ_spin.o \
paw_type.o \
partial_wave_expansion.o \
pseudovloc.o \
pseudo_q.o \
read_pseudo_ncpp.o \
read_pseudo_rrkj3.o \
run_pseudo.o \
run_test.o \
scf.o \
seriebes.o \
set_rho_core.o \
set_psi_in.o \
set_rc_rv.o \
set_sl3.o \
sic_correction.o \
starting_potential.o \
start_potps.o \
test_bessel.o \
trou.o \
vdpack.o \
vext.o \
vpack.o \
v_of_rho_at.o \
write_cpmd.o \
write_paw_recon.o \
write_pseudo.o \
write_results.o \
write_resultsps.o \
write_upf.o

LD1MODS = \
atomic_paw.o \
ld1inc.o \
parameters.o 

MODULES = \
../Modules/atom.o \
../Modules/cell_base.o \
../Modules/clocks.o \
../Modules/constants.o \
../Modules/control_flags.o \
../Modules/error_handler.o \
../Modules/exc_t.o \
../Modules/functionals.o \
../Modules/io_global.o \
../Modules/kind.o \
../Modules/ions_base.o \
../Modules/io_files.o \
../Modules/paw_variables.o \
../Modules/pseudo_types.o \
../Modules/radial_grids.o \
../Modules/read_upf_v1.o \
../Modules/read_upf_v2.o \
../Modules/random_numbers.o \
../Modules/timestep.o \
../Modules/version.o \
../Modules/parameters.o \
../Modules/parallel_include.o \
../Modules/parser.o \
../Modules/mp_global.o \
../Modules/mp.o \
../Modules/mp_base.o \
../Modules/fft_base.o \
../Modules/fft_types.o \
../Modules/uspp.o \
../Modules/upf.o \
../Modules/vxc_t.o \
../Modules/vxcgc.o \
../Modules/write_upf_v2.o \
../PW/para.o \
../PW/startup.o

TLDEPS= bindir mods libs 

all: tldeps ld1.x

ld1.x: $(LD1OBJS) ld1.o $(LD1MODS) $(MODULES) $(PHOBJS) $(LIBOBJS)
	$(LD) $(LDFLAGS) -o ld1.x \
		ld1.o $(LD1OBJS) $(LD1MODS) $(MODULES) $(PHOBJS) $(LIBOBJS) $(LIBS)
	- ( cd ../bin ; ln -fs ../atomic/ld1.x . )

pippo.x: $(LD1OBJS) pippo.o $(LD1MODS) $(MODULES) $(PHOBJS) $(LIBOBJS)
	$(LD) $(LDFLAGS) -o pippo.x \
		pippo.o $(LD1OBJS) $(LD1MODS) $(MODULES) $(PHOBJS) $(LIBOBJS) $(LIBS)


tldeps:
	test -n "$(TLDEPS)" && ( cd .. ; $(MAKE) $(MFLAGS) $(TLDEPS) || exit 1) || :

clean:
	- /bin/rm -f *.o *.F90 *.x $(LIB) *~ *.d *.mod *.tmp.* *.L

include make.depend
