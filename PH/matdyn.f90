! Copyright (C) 2001-2004 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
#include "f_defs.h"
!
Module ifconstants
  !
  ! All variables read from file that need dynamical allocation
  !
  USE kinds, ONLY: DP
  REAL(DP), ALLOCATABLE :: frc(:,:,:,:,:,:,:), tau_blk(:,:),  zeu(:,:,:)
  ! frc : interatomic force constants in real space
  ! tau_blk : atomic positions for the original cell
  ! zeu : effective charges for the original cell
  INTEGER, ALLOCATABLE  :: ityp_blk(:)
  ! ityp_blk : atomic types for each atom of the original cell
  !
end Module ifconstants
!
!---------------------------------------------------------------------
PROGRAM matdyn
  !-----------------------------------------------------------------------
  !  this program calculates the phonon frequencies for a list of generic 
  !  q vectors starting from the interatomic force constants generated 
  !  from the dynamical matrices as written by DFPT phonon code through 
  !  the companion program q2r
  !
  !  matdyn can generate a supercell of the original cell for mass
  !  approximation calculation. If supercell data are not specified
  !  in input, the unit cell, lattice vectors, atom types and positions
  !  are read from the force constant file
  !
  !  Input cards: namelist &input
  !     flfrc     file produced by q2r containing force constants (needed)
  !      asr      (character) indicates the type of Acoustic Sum Rule imposed
  !               - 'no': no Acoustic Sum Rules imposed (default)
  !               - 'simple':  previous implementation of the asr used 
  !                  (3 translational asr imposed by correction of 
  !                  the diagonal elements of the force constants matrix)
  !               - 'crystal': 3 translational asr imposed by optimized 
  !                  correction of the force constants (projection).
  !               - 'one-dim': 3 translational asr + 1 rotational asr
  !                  imposed by optimized correction of the force constants
  !                  (the rotation axis is the direction of periodicity; 
  !                   it will work only if this axis considered is one of
  !                   the cartesian axis).
  !               - 'zero-dim': 3 translational asr + 3 rotational asr
  !                  imposed by optimized correction of the force constants
  !               Note that in certain cases, not all the rotational asr
  !               can be applied (e.g. if there are only 2 atoms in a 
  !               molecule or if all the atoms are aligned, etc.). 
  !               In these cases the supplementary asr are cancelled
  !               during the orthonormalization procedure (see below).
  !     dos       if .true. calculate phonon Density of States (DOS)
  !               using tetrahedra and a uniform q-point grid (see below)
  !               NB: may not work properly in noncubic materials
  !               if .false. calculate phonon bands from the list of q-points
  !               supplied in input
  !     nk1,nk2,nk3  uniform q-point grid for DOS calculation (includes q=0)
  !     deltaE    energy step, in cm^(-1), for DOS calculation: from min
  !               to max phonon energy (default: 1 cm^(-1) if ndos is 
  !               not specified)
  !     ndos      number of energy steps for DOS calculations
  !               (no default: calculated from deltaE if not specified)
  !     fldos     output file for dos (default: 'matdyn.dos')
  !               the dos is in states/cm(-1) plotted vs omega in cm(-1)
  !               and is normalised to 3*nat, i.e. the number of phonons
  !     flfrq     output file for frequencies (default: 'matdyn.freq')
  !     flvec     output file for normal modes (default: 'matdyn.modes')
  !     at        supercell lattice vectors - must form a superlattice of the 
  !               original lattice
  !     l1,l2,l3  supercell lattice vectors are original cell vectors
  !               multiplied by l1, l2, l3 respectively
  !     ntyp      number of atom types in the supercell
  !     amass     masses of atoms in the supercell
  !     readtau   read  atomic positions of the supercell from input
  !               (used to specify different masses)
  !     fltau     write atomic positions of the supercell to file "fltau"
  !               (default: fltau=' ', do not write)
  !
  !  if (readtau) atom types and positions in the supercell follow:
  !     (tau(i,na),i=1,3), ityp(na)
  !  Then, if (.not.dos) :
  !     nq         number of q-points
  !     (q(i,n), i=1,3)    nq q-points in 2pi/a units
  !  If q = 0, the direction qhat (q=>0) for the non-analytic part
  !  is extracted from the sequence of q-points as follows:
  !     qhat = q(n) - q(n-1)  or   qhat = q(n) - q(n+1) 
  !  depending on which one is available and nonzero.
  !  For low-symmetry crystals, specify twice q = 0 in the list
  !  if you want to have q = 0 results for two different directions
  !
  USE kinds,      ONLY : DP
  USE mp,         ONLY : mp_start, mp_env, mp_end, mp_barrier
  USE mp_global,  ONLY : nproc, mpime, mp_global_start  
  USE ifconstants
  !
  IMPLICIT NONE
  !
  INTEGER :: gid
  !
  ! variables *_blk refer to the original cell, other variables
  ! to the (super)cell (which may coincide with the original cell)
  !
  INTEGER:: nax, nax_blk
  INTEGER, PARAMETER:: ntypx=10, nrwsx=200
  REAL(DP), PARAMETER :: eps=1.0d-6,  rydcm1 = 13.6058d0*8065.5d0, &
       amconv = 1.66042d-24/9.1095d-28*0.5d0
  INTEGER :: nr1, nr2, nr3, nsc, nk1, nk2, nk3, ntetra, ibrav
  CHARACTER(LEN=256) :: flfrc, flfrq, flvec, fltau, fldos
  CHARACTER(LEN=10)  :: asr
  CHARACTER(LEN=9)   :: symm_type
  LOGICAL :: dos, has_zstar
  COMPLEX(DP), ALLOCATABLE :: dyn(:,:,:,:), dyn_blk(:,:,:,:)
  COMPLEX(DP), ALLOCATABLE :: z(:,:)
  REAL(DP), ALLOCATABLE:: tau(:,:), q(:,:), w2(:,:), freq(:,:)
  INTEGER, ALLOCATABLE:: tetra(:,:), ityp(:), itau_blk(:)
  REAL(DP) :: at(3,3), bg(3,3), omega,alat, &! cell parameters and volume
                  at_blk(3,3), bg_blk(3,3),  &! original cell
                  omega_blk,                 &! original cell volume
                  epsil(3,3),                &! dielectric tensor
                  amass(ntypx),              &! atomic masses
                  amass_blk(ntypx),          &! original atomic masses
                  atws(3,3),      &! lattice vector for WS initialization
                  rws(0:3,nrwsx)   ! nearest neighbor list, rws(0,*) = norm^2
  !
  INTEGER :: nat, nat_blk, ntyp, ntyp_blk, &
             l1, l2, l3,                   &! supercell dimensions
             nrws                          ! number of nearest neighbor
  !
  LOGICAL :: readtau, la2F
  !
  REAL(DP) :: qhat(3), qh, DeltaE, Emin=0._dp, Emax, E, DOSofE(1)
  INTEGER :: n, i, j, it, nq, nqx, na, nb, ndos, iout
  !
  NAMELIST /input/ flfrc, amass, asr, flfrq, flvec, at, dos,  &
       &           fldos, nk1, nk2, nk3, l1, l2, l3, ntyp, readtau, fltau, & 
                   la2F, ndos, DeltaE
  !
  !
  CALL mp_start()
  !
  CALL mp_env( nproc, mpime, gid )
  !
  IF ( mpime == 0 ) THEN
     !
     ! ... all calculations are done by the first cpu
     !
     ! set namelist default
     !
     dos = .FALSE.
     deltaE = 1.0d0
     ndos = 1
     nk1 = 0 
     nk2 = 0 
     nk3 = 0 
     asr  ='no'
     readtau=.FALSE.
     flfrc=' '
     fldos='matdyn.dos'
     flfrq='matdyn.freq'
     flvec='matdyn.modes'
     fltau=' '
     amass(:) =0.d0
     amass_blk(:) =0.d0
     at(:,:) = 0.d0
     ntyp = 0
     l1=1
     l2=1
     l3=1
     la2F=.false.
     !
     CALL input_from_file ( )
     !
     READ (5,input)
     !
     ! convert masses to atomic units
     !
     amass(:) = amass(:) * amconv
     !
     ! read force constants 
     !
     ntyp_blk = ntypx ! avoids fake out-of-bound error
     CALL readfc ( flfrc, nr1, nr2, nr3, epsil, nat_blk, &
          ibrav, symm_type, alat, at_blk, ntyp_blk, &
          amass_blk, omega_blk, has_zstar)
     !
     CALL recips ( at_blk(1,1),at_blk(1,2),at_blk(1,3),  &
          bg_blk(1,1),bg_blk(1,2),bg_blk(1,3) )
     !
     ! set up (super)cell
     !
     if (ntyp < 0) then
        call errore ('matdyn','wrong ntyp ', abs(ntyp))
     else if (ntyp == 0) then
        ntyp=ntyp_blk
     end if
     !
     ! masses (for mass approximation)
     ! 
     DO it=1,ntyp
        IF (amass(it) < 0.d0) THEN
           CALL errore ('matdyn','wrong mass in the namelist',it)
        ELSE IF (amass(it) == 0.d0) THEN
           IF (it.LE.ntyp_blk) THEN
              WRITE (*,'(a,i3,a,a)') ' mass for atomic type ',it,      &
                   &                     ' not given; uses mass from file ',flfrc
              amass(it) = amass_blk(it)
           ELSE
              CALL errore ('matdyn','missing mass in the namelist',it)
           END IF
        END IF
     END DO
     !
     ! lattice vectors
     !
     IF (SUM(ABS(at(:,:))) == 0.d0) THEN
        IF (l1.LE.0 .OR. l2.LE.0 .OR. l3.LE.0) CALL                    &
             &             errore ('matdyn',' wrong l1,l2 or l3',1)
        at(:,1) = at_blk(:,1)*DBLE(l1)
        at(:,2) = at_blk(:,2)*DBLE(l2)
        at(:,3) = at_blk(:,3)*DBLE(l3)
     END IF
     !
     CALL check_at(at,bg_blk,alat,omega)
     !
     ! the supercell contains "nsc" times the original unit cell
     !
     nsc = NINT(omega/omega_blk)
     IF (ABS(omega/omega_blk-nsc) > eps) &
          CALL errore ('matdyn', 'volume ratio not integer', 1)
     !
     ! read/generate atomic positions of the (super)cell
     !
     nat = nat_blk * nsc
     nax = nat
     !!!
     nax_blk = nat_blk
     !!!
     ALLOCATE ( tau (3, nat), ityp(nat), itau_blk(nat_blk) )
     !
     IF (readtau) THEN
        CALL read_tau &
             (nat, nat_blk, ntyp, bg_blk, tau, tau_blk, ityp, itau_blk)
     ELSE
        CALL set_tau  &
             (nat, nat_blk, at, at_blk, tau, tau_blk, ityp, ityp_blk, itau_blk)
     ENDIF
     !
     IF (fltau.NE.' ') CALL write_tau (fltau, nat, tau, ityp)
     !
     ! reciprocal lattice vectors
     !
     CALL recips (at(1,1),at(1,2),at(1,3),bg(1,1),bg(1,2),bg(1,3))
     !
     ! build the WS cell corresponding to the force constant grid
     !
     atws(:,1) = at_blk(:,1)*DBLE(nr1)
     atws(:,2) = at_blk(:,2)*DBLE(nr2)
     atws(:,3) = at_blk(:,3)*DBLE(nr3)
     ! initialize WS r-vectors
     CALL wsinit(rws,nrwsx,nrws,atws)
     !
     ! end of (super)cell setup
     !
     IF (dos) THEN
        IF (nk1 < 1 .OR. nk2 < 1 .OR. nk3 < 1) &
             CALL errore  ('matdyn','specify correct q-point grid!',1)
        ntetra = 6 * nk1 * nk2 * nk3
        nqx = nk1*nk2*nk3
        ALLOCATE ( tetra(4,ntetra), q(3,nqx) )
        CALL gen_qpoints (ibrav, at, bg, nat, tau, ityp, nk1, nk2, nk3, &
             symm_type, ntetra, nqx, nq, q, tetra)
     ELSE
        !
        ! read q-point list
        !
        READ (5,*) nq
        ALLOCATE ( q(3,nq) )
        ALLOCATE( tetra(0,0) )
        DO n = 1,nq
           READ (5,*) (q(i,n),i=1,3)
        END DO
     END IF
     !
     IF (asr /= 'no') THEN
        CALL set_asr (asr, nr1, nr2, nr3, frc, zeu, &
             nat_blk, ibrav, tau_blk)
     END IF
     !
     IF (flvec.EQ.' ') THEN
        iout=6
     ELSE
        iout=4
        OPEN (unit=iout,file=flvec,status='unknown',form='formatted')
     END IF

     ALLOCATE ( dyn(3,3,nat,nat), dyn_blk(3,3,nat_blk,nat_blk) )
     ALLOCATE ( z(3*nat,3*nat), w2(3*nat,nq) )

     if(la2F) open(300,file='dyna2F',status='unknown')

     DO n=1, nq
        dyn(:,:,:,:) = (0.d0, 0.d0)

        CALL setupmat (q(1,n), dyn, nat, at, bg, tau, itau_blk, nsc, alat, &
             dyn_blk, nat_blk, at_blk, bg_blk, tau_blk, omega_blk,  &
             epsil, zeu, frc, nr1,nr2,nr3, has_zstar, rws, nrws)

        IF (q(1,n)==0.d0 .AND. q(2,n)==0.d0 .AND. q(3,n)==0.d0) THEN
           !
           ! q = 0 : we need the direction q => 0 for the non-analytic part
           !
           IF ( n == 1 ) THEN
              ! if q is the first point in the list
              IF ( nq > 1 ) THEN
                 ! one more point
                 qhat(:) = q(:,n) - q(:,n+1)
              ELSE
                 ! no more points
                 qhat(:) = 0.d0
              END IF
           ELSE IF ( n > 1 ) THEN
              ! if q is not the first point in the list
              IF ( q(1,n-1)==0.d0 .AND. &
                   q(2,n-1)==0.d0 .AND. &
                   q(3,n-1)==0.d0 .AND. n < nq ) THEN
                 ! if the preceding q is also 0 :
                 qhat(:) = q(:,n) - q(:,n+1)
              ELSE
                 ! if the preceding q is npt 0 :
                 qhat(:) = q(:,n) - q(:,n-1)
              END IF
           END IF
           qh = SQRT(qhat(1)**2+qhat(2)**2+qhat(3)**2)
           ! write(*,*) ' qh,  has_zstar ',qh,  has_zstar
           IF (qh /= 0.d0) qhat(:) = qhat(:) / qh
           IF (qh /= 0.d0 .AND. .NOT. has_zstar) CALL infomsg  &
                ('matdyn','Z* not found in file '//TRIM(flfrc)// &
                          ', TO-LO splitting at q=0 will be absent!')
           !
           CALL nonanal (nat, nat_blk, itau_blk, epsil, qhat, zeu, omega, dyn)
           !
        END IF
        !
        CALL dyndiag(nat,ntyp,amass,ityp,dyn,w2(1,n),z)
        !
        if(la2F) then
           write(300,*) n
           do na=1,3*nat
              write(300,*) (z(na,nb),nb=1,3*nat)
           end do ! na
        endif
        !
        CALL writemodes(nax,nat,q(1,n),w2(1,n),z,iout)
        !
     END DO  !nq
     if(la2F) close(300)
     !
     IF(iout .NE. 6) CLOSE(unit=iout)
     !
     ALLOCATE (freq(3*nat, nq))
     DO n=1,nq
        ! freq(i,n) = frequencies in cm^(-1), with negative sign if omega^2 is negative
        DO i=1,3*nat
           freq(i,n)= SQRT(ABS(w2(i,n))) * rydcm1
           IF (w2(i,n) < 0.0d0) freq(i,n) = -freq(i,n)
        END DO
     END DO
     !
     IF(flfrq.NE.' ') THEN
        OPEN (unit=2,file=flfrq ,status='unknown',form='formatted')
        WRITE(2, '(" &plot nbnd=",i4,", nks=",i4," /")') 3*nat, nq
        DO n=1, nq
           WRITE(2, '(10x,3f10.6)')  q(1,n), q(2,n), q(3,n)
           WRITE(2,'(6f10.4)') (freq(i,n), i=1,3*nat)
        END DO
        CLOSE(unit=2)
     END IF
     !
     !
     IF (dos) THEN
        Emin = 0.0d0 
        Emax = 0.0d0
        DO n=1,nq
           DO i=1, 3*nat
              Emin = MIN (Emin, freq(i,n))
              Emax = MAX (Emax, freq(i,n))
           END DO
        END DO
        !
        if (ndos > 1) then
           DeltaE = (Emax - Emin)/(ndos-1)
        else
           ndos = NINT ( (Emax - Emin) / DeltaE + 1.51d0 )  
        end if
        OPEN (unit=2,file=fldos,status='unknown',form='formatted')
        DO n= 1, ndos  
           E = Emin + (n - 1) * DeltaE  
           CALL dos_t(freq, 1, 3*nat, nq, ntetra, tetra, E, DOSofE)
           !
           ! The factor 0.5 corrects for the factor 2 in dos_t,
           ! that accounts for the spin in the electron DOS.
           !
           !WRITE (2, '(F15.10,F15.2,F15.6,F20.5)') &
           !     E, E*rydcm1, E*rydTHz, 0.5d0*DOSofE(1)
           WRITE (2, '(E12.4,E12.4)') E, 0.5d0*DOSofE(1)
        END DO
        CLOSE(unit=2)
     END IF  !dos
     DEALLOCATE (z, w2, dyn, dyn_blk)
     !
     !    for a2F
     !
     IF(la2F) THEN
         !
         ! convert frequencies to Ry
         !
         freq(:,:)= freq(:,:) / rydcm1
         Emin  = Emin / rydcm1
         DeltaE=DeltaE/ rydcm1
         !
         call a2Fdos (nat, nq, nr1, nr2, nr3, ibrav, at, bg, tau, alat, &
                           nsc, nat_blk, at_blk, bg_blk, itau_blk, omega_blk, &
                           rws, nrws, dos, Emin, DeltaE, ndos, &
                           ntetra, tetra, asr, q, freq)
     END IF
     DEALLOCATE ( freq)
     !
  END IF
  ! 
  CALL mp_barrier()
  !
  CALL mp_end()
  !
  STOP
  !
END PROGRAM matdyn
!
!-----------------------------------------------------------------------
SUBROUTINE readfc ( flfrc, nr1, nr2, nr3, epsil, nat,    &
                    ibrav, symm_type, alat, at, ntyp, amass, omega, has_zstar )
  !-----------------------------------------------------------------------
  !
  USE kinds,      ONLY : DP
  USE ifconstants,ONLY : tau => tau_blk, ityp => ityp_blk, frc, zeu
  !
  IMPLICIT NONE
  ! I/O variable
  CHARACTER(LEN=256) flfrc
  INTEGER ibrav, nr1,nr2,nr3,nat, ntyp
  REAL(DP) alat, at(3,3), epsil(3,3)
  LOGICAL has_zstar
  ! local variables
  INTEGER i, j, na, nb, m1,m2,m3
  INTEGER ibid, jbid, nabid, nbbid, m1bid,m2bid,m3bid
  REAL(DP) amass(ntyp), amass_from_file, celldm(6), omega
  INTEGER nt
  CHARACTER(LEN=3) atm
  CHARACTER(LEN=9) symm_type
  !
  !
  OPEN (unit=1,file=flfrc,status='old',form='formatted')
  !
  !  read cell data
  !
  READ(1,*) ntyp,nat,ibrav,(celldm(i),i=1,6)
  if (ibrav==0) then
     read(1,'(a)') symm_type
     read(1,*) ((at(i,j),i=1,3),j=1,3)
  end if
  !
  CALL latgen(ibrav,celldm,at(1,1),at(1,2),at(1,3),omega)
  alat = celldm(1)
  at = at / alat !  bring at in units of alat
  CALL volume(alat,at(1,1),at(1,2),at(1,3),omega)
  !
  !  read atomic types, positions and masses
  !
  DO nt = 1,ntyp
     READ(1,*) i,atm,amass_from_file
     IF (i.NE.nt) CALL errore ('readfc','wrong data read',nt)
     IF (amass(nt).EQ.0.d0) THEN
        amass(nt) = amass_from_file
     ELSE
        WRITE(*,*) 'for atomic type',nt,' mass from file not used'
     END IF
  END DO
  !
  ALLOCATE (tau(3,nat), ityp(nat), zeu(3,3,nat))
  !
  DO na=1,nat
     READ(1,*) i,ityp(na),(tau(j,na),j=1,3)
     IF (i.NE.na) CALL errore ('readfc','wrong data read',na)
  END DO
  !
  !  read macroscopic variable
  !
  READ (1,*) has_zstar
  IF (has_zstar) THEN
     READ(1,*) ((epsil(i,j),j=1,3),i=1,3)
     DO na=1,nat
        READ(1,*) 
        READ(1,*) ((zeu(i,j,na),j=1,3),i=1,3)
     END DO
  ELSE
     zeu  (:,:,:) = 0.d0
     epsil(:,:) = 0.d0
  END IF
  !
  READ (1,*) nr1,nr2,nr3
  !
  !  read real-space interatomic force constants
  !
  ALLOCATE ( frc(nr1,nr2,nr3,3,3,nat,nat) )
  frc(:,:,:,:,:,:,:) = 0.d0
  DO i=1,3
     DO j=1,3
        DO na=1,nat
           DO nb=1,nat
              READ (1,*) ibid, jbid, nabid, nbbid
              IF(i .NE.ibid  .OR. j .NE.jbid .OR.                   &
                 na.NE.nabid .OR. nb.NE.nbbid)                      &
                 CALL errore  ('readfc','error in reading',1)
              READ (1,*) (((m1bid, m2bid, m3bid,                    &
                          frc(m1,m2,m3,i,j,na,nb),                  &
                           m1=1,nr1),m2=1,nr2),m3=1,nr3)
           END DO
        END DO
     END DO
  END DO
  !
  CLOSE(unit=1)
  !
  RETURN
END SUBROUTINE readfc
!
!-----------------------------------------------------------------------
SUBROUTINE frc_blk(dyn,q,tau,nat,nr1,nr2,nr3,frc,at,bg,rws,nrws)
  !-----------------------------------------------------------------------
  ! calculates the dynamical matrix at q from the (short-range part of the)
  ! force constants 
  !
  USE kinds,      ONLY : DP
  USE constants,  ONLY : tpi
  !
  IMPLICIT NONE
  INTEGER nr1, nr2, nr3, nat, n1, n2, n3, &
          ipol, jpol, na, nb, m1, m2, m3, nint, i,j, nrws
  COMPLEX(DP) dyn(3,3,nat,nat)
  REAL(DP) frc(nr1,nr2,nr3,3,3,nat,nat), tau(3,nat), q(3), arg, &
               at(3,3), bg(3,3), r(3), weight, r_ws(3),  &
               total_weight, rws(0:3,nrws)
  REAL(DP), EXTERNAL :: wsweight
  !
  DO na=1, nat
     DO nb=1, nat
        total_weight=0.0d0
        DO n1=-2*nr1,2*nr1
           DO n2=-2*nr2,2*nr2
              DO n3=-2*nr3,2*nr3
                 !
                 ! SUM OVER R VECTORS IN THE SUPERCELL - VERY VERY SAFE RANGE!
                 !
                 DO i=1, 3
                    r(i) = n1*at(i,1)+n2*at(i,2)+n3*at(i,3)
                    r_ws(i) = r(i) + tau(i,na)-tau(i,nb)
                 END DO
                 weight = wsweight(r_ws,rws,nrws)
                 IF (weight .GT. 0.0d0) THEN
                    !
                    ! FIND THE VECTOR CORRESPONDING TO R IN THE ORIGINAL CELL
                    !
                    m1 = MOD(n1+1,nr1)
                    IF(m1.LE.0) m1=m1+nr1
                    m2 = MOD(n2+1,nr2)
                    IF(m2.LE.0) m2=m2+nr2
                    m3 = MOD(n3+1,nr3)
                    IF(m3.LE.0) m3=m3+nr3
                    !
                    ! FOURIER TRANSFORM
                    !
                    arg = tpi*(q(1)*r(1) + q(2)*r(2) + q(3)*r(3))
                    DO ipol=1, 3
                       DO jpol=1, 3
                          dyn(ipol,jpol,na,nb) =                 &
                               dyn(ipol,jpol,na,nb) +            &
                               frc(m1,m2,m3,ipol,jpol,na,nb)     &
                               *CMPLX(COS(arg),-SIN(arg))*weight
                       END DO
                    END DO
                 END IF
                 total_weight=total_weight + weight
              END DO
           END DO
        END DO
        IF (ABS(total_weight-nr1*nr2*nr3).GT.1.0d-8) THEN
           WRITE(*,*) total_weight
           CALL errore ('frc_blk','wrong total_weight',1)
        END IF
     END DO
  END DO
  !
  RETURN
END SUBROUTINE frc_blk
!
!-----------------------------------------------------------------------
SUBROUTINE setupmat (q,dyn,nat,at,bg,tau,itau_blk,nsc,alat, &
     &         dyn_blk,nat_blk,at_blk,bg_blk,tau_blk,omega_blk, &
     &                 epsil,zeu,frc,nr1,nr2,nr3,has_zstar,rws,nrws)
  !-----------------------------------------------------------------------
  ! compute the dynamical matrix (the analytic part only)
  !
  USE kinds,      ONLY : DP
  USE constants,  ONLY : tpi
  !
  IMPLICIT NONE
  !
  ! I/O variables
  !
  INTEGER:: nr1, nr2, nr3, nat, nat_blk, nsc, nrws, itau_blk(nat)
  REAL(DP) :: q(3), tau(3,nat), at(3,3), bg(3,3), alat,      &
                  epsil(3,3), zeu(3,3,nat_blk), rws(0:3,nrws),   &
                  frc(nr1,nr2,nr3,3,3,nat_blk,nat_blk)
  REAL(DP) :: tau_blk(3,nat_blk), at_blk(3,3), bg_blk(3,3), omega_blk
  COMPLEX(DP) dyn_blk(3,3,nat_blk,nat_blk)
  COMPLEX(DP) ::  dyn(3,3,nat,nat)
  LOGICAL has_zstar
  !
  ! local variables
  !
  REAL(DP) :: arg
  COMPLEX(DP) :: cfac(nat)
  INTEGER :: i,j,k, na,nb, na_blk, nb_blk, iq
  REAL(DP) qp(3), qbid(3,nsc) ! automatic array
  !
  !
  CALL q_gen(nsc,qbid,at_blk,bg_blk,at,bg)
  !
  DO iq=1,nsc
     !
     DO k=1,3
        qp(k)= q(k) + qbid(k,iq)
     END DO
     !
     dyn_blk(:,:,:,:) = (0.d0,0.d0)
     CALL frc_blk (dyn_blk,qp,tau_blk,nat_blk,              &
          &              nr1,nr2,nr3,frc,at_blk,bg_blk,rws,nrws)
     IF (has_zstar) &
          CALL rgd_blk(nr1,nr2,nr3,nat_blk,dyn_blk,qp,tau_blk,   &
                       epsil,zeu,bg_blk,omega_blk,+1.d0)
     !
     DO na=1,nat
        na_blk = itau_blk(na)
        DO nb=1,nat
           nb_blk = itau_blk(nb)
           !
           arg=tpi* ( qp(1) * ( (tau(1,na)-tau_blk(1,na_blk)) -   &
                                (tau(1,nb)-tau_blk(1,nb_blk)) ) + &
                      qp(2) * ( (tau(2,na)-tau_blk(2,na_blk)) -   &
                                (tau(2,nb)-tau_blk(2,nb_blk)) ) + &
                      qp(3) * ( (tau(3,na)-tau_blk(3,na_blk)) -   &
                                (tau(3,nb)-tau_blk(3,nb_blk)) ) )
           !
           cfac(nb) = CMPLX(COS(arg),SIN(arg))/nsc
           !
        END DO ! nb
        !
        DO i=1,3
           DO j=1,3
              !
              DO nb=1,nat
                 nb_blk = itau_blk(nb)
                 dyn(i,j,na,nb) = dyn(i,j,na,nb) + cfac(nb) * &
                      dyn_blk(i,j,na_blk,nb_blk)
              END DO ! nb
              !
           END DO ! j
        END DO ! i
     END DO ! na
     !
  END DO ! iq
  !
  RETURN
END SUBROUTINE setupmat
!
!
!----------------------------------------------------------------------
SUBROUTINE set_asr (asr, nr1, nr2, nr3, frc, zeu, nat, ibrav, tau)
  !-----------------------------------------------------------------------
  !
  USE kinds,      ONLY : DP
  !
  IMPLICIT NONE
  CHARACTER (LEN=10), intent(in) :: asr
  INTEGER, intent(in) :: nr1, nr2, nr3, nat, ibrav
  REAL(DP), intent(in) :: tau(3,nat)
  REAL(DP), intent(inout) :: frc(nr1,nr2,nr3,3,3,nat,nat), zeu(3,3,nat)
  !
  INTEGER :: axis, n, i, j, na, nb, n1,n2,n3, m,p,k,l,q,r, i1,j1,na1
  REAL(DP) :: zeu_new(3,3,nat)
  REAL(DP), ALLOCATABLE :: frc_new(:,:,:,:,:,:,:)
  type vector
     real(DP),pointer :: vec(:,:,:,:,:,:,:)
  end type vector
  ! 
  type (vector) u(6*3*nat)
  ! These are the "vectors" associated with the sum rules on force-constants
  !
  integer :: u_less(6*3*nat),n_less,i_less
  ! indices of the vectors u that are not independent to the preceding ones,
  ! n_less = number of such vectors, i_less = temporary parameter
  !
  integer, allocatable :: ind_v(:,:,:)
  real(DP), allocatable :: v(:,:)
  ! These are the "vectors" associated with symmetry conditions, coded by 
  ! indicating the positions (i.e. the seven indices) of the non-zero elements (there
  ! should be only 2 of them) and the value of that element. We do so in order
  ! to limit the amount of memory used. 
  !
  real(DP), allocatable :: w(:,:,:,:,:,:,:), x(:,:,:,:,:,:,:)
  ! temporary vectors and parameters  
  real(DP) :: scal,norm2, sum
  !
  real(DP) :: zeu_u(6*3,3,3,nat)
  ! These are the "vectors" associated with the sum rules on effective charges
  !
  integer :: zeu_less(6*3),nzeu_less,izeu_less
  ! indices of the vectors zeu_u that are not independent to the preceding ones,
  ! nzeu_less = number of such vectors, izeu_less = temporary parameter
  !
  real(DP) :: zeu_w(3,3,nat), zeu_x(3,3,nat)
  ! temporary vectors

  ! Initialization. n is the number of sum rules to be considered (if asr.ne.'simple')
  ! and 'axis' is the rotation axis in the case of a 1D system
  ! (i.e. the rotation axis is (Ox) if axis='1', (Oy) if axis='2' and (Oz) if axis='3') 
  !
  if((asr.ne.'simple').and.(asr.ne.'crystal').and.(asr.ne.'one-dim') &
                      .and.(asr.ne.'zero-dim')) then
     call errore('matdyn','invalid Acoustic Sum Rule:' // asr, 1)
  endif
  !
  if(asr.eq.'simple') then
     !
     ! Simple Acoustic Sum Rule on effective charges
     !     
     do i=1,3
        do j=1,3
           sum=0.0d0
           do na=1,nat
              sum = sum + zeu(i,j,na)
           end do
           do na=1,nat
              zeu(i,j,na) = zeu(i,j,na) - sum/nat
           end do
        end do
     end do
     !
     ! Simple Acoustic Sum Rule on force constants in real space
     !
     do i=1,3
        do j=1,3
           do na=1,nat
              sum=0.0d0
               do nb=1,nat
                  do n1=1,nr1
                     do n2=1,nr2
                        do n3=1,nr3
                           sum=sum+frc(n1,n2,n3,i,j,na,nb)
                        end do
                     end do
                  end do
               end do
               frc(1,1,1,i,j,na,na) = frc(1,1,1,i,j,na,na) - sum
               !               write(6,*) ' na, i, j, sum = ',na,i,j,sum
            end do
         end do
      end do
      !
      return 
      !
   end if

  if(asr.eq.'crystal') n=3
  if(asr.eq.'one-dim') then
     ! the direction of periodicity is the rotation axis
     ! It will work only if the crystal axis considered is one of
     ! the cartesian axis (typically, ibrav=1, 6 or 8, or 4 along the
     ! z-direction)
     if (nr1*nr2*nr3.eq.1) axis=3
     if ((nr1.ne.1).and.(nr2*nr3.eq.1)) axis=1
     if ((nr2.ne.1).and.(nr1*nr3.eq.1)) axis=2
     if ((nr3.ne.1).and.(nr1*nr2.eq.1)) axis=3
     if (((nr1.ne.1).and.(nr2.ne.1)).or.((nr2.ne.1).and. &
          (nr3.ne.1)).or.((nr1.ne.1).and.(nr3.ne.1))) then
        call errore('matdyn','too many directions of &
             & periodicity in 1D system',axis)
     endif
     if ((ibrav.ne.1).and.(ibrav.ne.6).and.(ibrav.ne.8).and. &
          ((ibrav.ne.4).or.(axis.ne.3)) ) then
        write(6,*) 'asr: rotational axis may be wrong'
     endif
     write(6,'("asr rotation axis in 1D system= ",I4)') axis
     n=4
  endif
  if(asr.eq.'zero-dim') n=6
  !
  ! Acoustic Sum Rule on effective charges
  !
  ! generating the vectors of the orthogonal of the subspace to project 
  ! the effective charges matrix on
  !
  zeu_u(:,:,:,:)=0.0d0
  do i=1,3
     do j=1,3
        do na=1,nat
           zeu_new(i,j,na)=zeu(i,j,na)
        enddo
     enddo
  enddo
  !
  p=0
  do i=1,3
     do j=1,3
        ! These are the 3*3 vectors associated with the 
        ! translational acoustic sum rules
        p=p+1
        zeu_u(p,i,j,:)=1.0d0
        !
     enddo
  enddo
  !
  if (n.eq.4) then
     do i=1,3
        ! These are the 3 vectors associated with the 
        ! single rotational sum rule (1D system)
        p=p+1
        do na=1,nat
           zeu_u(p,i,MOD(axis,3)+1,na)=-tau(MOD(axis+1,3)+1,na)
           zeu_u(p,i,MOD(axis+1,3)+1,na)=tau(MOD(axis,3)+1,na)
        enddo
        !
     enddo
  endif
  !
  if (n.eq.6) then
     do i=1,3
        do j=1,3
           ! These are the 3*3 vectors associated with the 
           ! three rotational sum rules (0D system - typ. molecule)
           p=p+1
           do na=1,nat
              zeu_u(p,i,MOD(j,3)+1,na)=-tau(MOD(j+1,3)+1,na)
              zeu_u(p,i,MOD(j+1,3)+1,na)=tau(MOD(j,3)+1,na)
           enddo
           !
        enddo
     enddo
  endif
  !
  ! Gram-Schmidt orthonormalization of the set of vectors created.
  !
  nzeu_less=0
  do k=1,p
     zeu_w(:,:,:)=zeu_u(k,:,:,:)
     zeu_x(:,:,:)=zeu_u(k,:,:,:)
     do q=1,k-1
        r=1
        do izeu_less=1,nzeu_less
           if (zeu_less(izeu_less).eq.q) r=0
        enddo
        if (r.ne.0) then
           call sp_zeu(zeu_x,zeu_u(q,:,:,:),nat,scal)
           zeu_w(:,:,:) = zeu_w(:,:,:) - scal* zeu_u(q,:,:,:)
        endif
     enddo
     call sp_zeu(zeu_w,zeu_w,nat,norm2)
     if (norm2.gt.1.0d-16) then
        zeu_u(k,:,:,:) = zeu_w(:,:,:) / DSQRT(norm2)
     else
        nzeu_less=nzeu_less+1
        zeu_less(nzeu_less)=k
     endif
  enddo
  !
  ! Projection of the effective charge "vector" on the orthogonal of the 
  ! subspace of the vectors verifying the sum rules
  !
  zeu_w(:,:,:)=0.0d0
  do k=1,p
     r=1
     do izeu_less=1,nzeu_less
        if (zeu_less(izeu_less).eq.k) r=0
     enddo
     if (r.ne.0) then
        zeu_x(:,:,:)=zeu_u(k,:,:,:)
        call sp_zeu(zeu_x,zeu_new,nat,scal)
        zeu_w(:,:,:) = zeu_w(:,:,:) + scal*zeu_u(k,:,:,:)
     endif
  enddo
  !
  ! Final substraction of the former projection to the initial zeu, to get
  ! the new "projected" zeu
  !
  zeu_new(:,:,:)=zeu_new(:,:,:) - zeu_w(:,:,:)
  call sp_zeu(zeu_w,zeu_w,nat,norm2)
  write(6,'("Norm of the difference between old and new effective ", &
       & "charges: ",F25.20)') SQRT(norm2)
  !
  ! Check projection
  !
  !write(6,'("Check projection of zeu")')
  !do k=1,p
  !  zeu_x(:,:,:)=zeu_u(k,:,:,:)
  !  call sp_zeu(zeu_x,zeu_new,nat,scal)
  !  if (DABS(scal).gt.1d-10) write(6,'("k= ",I8," zeu_new|zeu_u(k)= ",F15.10)') k,scal
  !enddo
  !
  do i=1,3
     do j=1,3
        do na=1,nat
           zeu(i,j,na)=zeu_new(i,j,na)
        enddo
     enddo
  enddo
  !
  ! Acoustic Sum Rule on force constants
  !
  !
  ! generating the vectors of the orthogonal of the subspace to project 
  ! the force-constants matrix on
  !
  do k=1,18*nat
     allocate(u(k) % vec(nr1,nr2,nr3,3,3,nat,nat))
     u(k) % vec (:,:,:,:,:,:,:)=0.0d0
  enddo
  ALLOCATE (frc_new(nr1,nr2,nr3,3,3,nat,nat))
  do i=1,3
     do j=1,3
        do na=1,nat
           do nb=1,nat
              do n1=1,nr1
                 do n2=1,nr2
                    do n3=1,nr3
                       frc_new(n1,n2,n3,i,j,na,nb)=frc(n1,n2,n3,i,j,na,nb)
                    enddo
                 enddo
              enddo
           enddo
        enddo
     enddo
  enddo
  !
  p=0
  do i=1,3
     do j=1,3
        do na=1,nat
           ! These are the 3*3*nat vectors associated with the 
           ! translational acoustic sum rules
           p=p+1
           u(p) % vec (:,:,:,i,j,na,:)=1.0d0
           !
        enddo
     enddo
  enddo
  !
  if (n.eq.4) then
     do i=1,3
        do na=1,nat
           ! These are the 3*nat vectors associated with the 
           ! single rotational sum rule (1D system)
           p=p+1
           do nb=1,nat
              u(p) % vec (:,:,:,i,MOD(axis,3)+1,na,nb)=-tau(MOD(axis+1,3)+1,nb)
              u(p) % vec (:,:,:,i,MOD(axis+1,3)+1,na,nb)=tau(MOD(axis,3)+1,nb)
           enddo
           !
        enddo
     enddo
  endif
  !
  if (n.eq.6) then
     do i=1,3
        do j=1,3
           do na=1,nat
              ! These are the 3*3*nat vectors associated with the 
              ! three rotational sum rules (0D system - typ. molecule)
              p=p+1
              do nb=1,nat
                 u(p) % vec (:,:,:,i,MOD(j,3)+1,na,nb)=-tau(MOD(j+1,3)+1,nb)
                 u(p) % vec (:,:,:,i,MOD(j+1,3)+1,na,nb)=tau(MOD(j,3)+1,nb)
              enddo
              !
           enddo
        enddo
     enddo
  endif
  !
  allocate (ind_v(9*nat*nat*nr1*nr2*nr3,2,7), v(9*nat*nat*nr1*nr2*nr3,2) )
  m=0
  do i=1,3
     do j=1,3
        do na=1,nat
           do nb=1,nat
              do n1=1,nr1
                 do n2=1,nr2
                    do n3=1,nr3
                       ! These are the vectors associated with the symmetry constraints
                       q=1
                       l=1
                       do while((l.le.m).and.(q.ne.0))
                          if ((ind_v(l,1,1).eq.n1).and.(ind_v(l,1,2).eq.n2).and. &
                               (ind_v(l,1,3).eq.n3).and.(ind_v(l,1,4).eq.i).and. &
                               (ind_v(l,1,5).eq.j).and.(ind_v(l,1,6).eq.na).and. &
                               (ind_v(l,1,7).eq.nb)) q=0
                          if ((ind_v(l,2,1).eq.n1).and.(ind_v(l,2,2).eq.n2).and. &
                               (ind_v(l,2,3).eq.n3).and.(ind_v(l,2,4).eq.i).and. &
                               (ind_v(l,2,5).eq.j).and.(ind_v(l,2,6).eq.na).and. &
                               (ind_v(l,2,7).eq.nb)) q=0
                          l=l+1
                       enddo
                       if ((n1.eq.MOD(nr1+1-n1,nr1)+1).and.(n2.eq.MOD(nr2+1-n2,nr2)+1) &
                            .and.(n3.eq.MOD(nr3+1-n3,nr3)+1).and.(i.eq.j).and.(na.eq.nb)) q=0
                       if (q.ne.0) then
                          m=m+1
                          ind_v(m,1,1)=n1
                          ind_v(m,1,2)=n2
                          ind_v(m,1,3)=n3
                          ind_v(m,1,4)=i
                          ind_v(m,1,5)=j
                          ind_v(m,1,6)=na
                          ind_v(m,1,7)=nb
                          v(m,1)=1.0d0/DSQRT(2.0d0)
                          ind_v(m,2,1)=MOD(nr1+1-n1,nr1)+1
                          ind_v(m,2,2)=MOD(nr2+1-n2,nr2)+1
                          ind_v(m,2,3)=MOD(nr3+1-n3,nr3)+1
                          ind_v(m,2,4)=j
                          ind_v(m,2,5)=i
                          ind_v(m,2,6)=nb
                          ind_v(m,2,7)=na
                          v(m,2)=-1.0d0/DSQRT(2.0d0)
                       endif
                    enddo
                 enddo
              enddo
           enddo
        enddo
     enddo
  enddo
  !
  ! Gram-Schmidt orthonormalization of the set of vectors created.
  ! Note that the vectors corresponding to symmetry constraints are already
  ! orthonormalized by construction.
  !
  n_less=0
  allocate (w(nr1,nr2,nr3,3,3,nat,nat), x(nr1,nr2,nr3,3,3,nat,nat))
  do k=1,p
     w(:,:,:,:,:,:,:)=u(k) % vec (:,:,:,:,:,:,:)
     x(:,:,:,:,:,:,:)=u(k) % vec (:,:,:,:,:,:,:)
     do l=1,m
        !
        call sp2(x,v(l,:),ind_v(l,:,:),nr1,nr2,nr3,nat,scal)
        do r=1,2
           n1=ind_v(l,r,1)
           n2=ind_v(l,r,2)
           n3=ind_v(l,r,3)
           i=ind_v(l,r,4)
           j=ind_v(l,r,5)
           na=ind_v(l,r,6)
           nb=ind_v(l,r,7)
           w(n1,n2,n3,i,j,na,nb)=w(n1,n2,n3,i,j,na,nb)-scal*v(l,r)
        enddo
     enddo
     if (k.le.(9*nat)) then
        na1=MOD(k,nat)
        if (na1.eq.0) na1=nat
        j1=MOD((k-na1)/nat,3)+1
        i1=MOD((((k-na1)/nat)-j1+1)/3,3)+1
     else
        q=k-9*nat
        if (n.eq.4) then
           na1=MOD(q,nat)
           if (na1.eq.0) na1=nat
           i1=MOD((q-na1)/nat,3)+1
        else
           na1=MOD(q,nat)
           if (na1.eq.0) na1=nat
           j1=MOD((q-na1)/nat,3)+1
           i1=MOD((((q-na1)/nat)-j1+1)/3,3)+1
        endif
     endif
     do q=1,k-1
        r=1
        do i_less=1,n_less
           if (u_less(i_less).eq.q) r=0
        enddo
        if (r.ne.0) then
           call sp3(x,u(q) % vec (:,:,:,:,:,:,:), i1,na1,nr1,nr2,nr3,nat,scal)
           w(:,:,:,:,:,:,:) = w(:,:,:,:,:,:,:) - scal* u(q) % vec (:,:,:,:,:,:,:)
        endif
     enddo
     call sp1(w,w,nr1,nr2,nr3,nat,norm2)
     if (norm2.gt.1.0d-16) then
        u(k) % vec (:,:,:,:,:,:,:) = w(:,:,:,:,:,:,:) / DSQRT(norm2)
     else
        n_less=n_less+1
        u_less(n_less)=k
     endif
  enddo
  !
  ! Projection of the force-constants "vector" on the orthogonal of the 
  ! subspace of the vectors verifying the sum rules and symmetry contraints
  !
  w(:,:,:,:,:,:,:)=0.0d0
  do l=1,m
     call sp2(frc_new,v(l,:),ind_v(l,:,:),nr1,nr2,nr3,nat,scal)
     do r=1,2
        n1=ind_v(l,r,1)
        n2=ind_v(l,r,2)
        n3=ind_v(l,r,3)
        i=ind_v(l,r,4)
        j=ind_v(l,r,5)
        na=ind_v(l,r,6)
        nb=ind_v(l,r,7)
        w(n1,n2,n3,i,j,na,nb)=w(n1,n2,n3,i,j,na,nb)+scal*v(l,r)
     enddo
  enddo
  do k=1,p
     r=1
     do i_less=1,n_less
        if (u_less(i_less).eq.k) r=0
     enddo
     if (r.ne.0) then
        x(:,:,:,:,:,:,:)=u(k) % vec (:,:,:,:,:,:,:)
        call sp1(x,frc_new,nr1,nr2,nr3,nat,scal)
        w(:,:,:,:,:,:,:) = w(:,:,:,:,:,:,:) + scal*u(k)%vec(:,:,:,:,:,:,:)
     endif
     deallocate(u(k) % vec)
  enddo
  !
  ! Final substraction of the former projection to the initial frc, to get
  ! the new "projected" frc
  !
  frc_new(:,:,:,:,:,:,:)=frc_new(:,:,:,:,:,:,:) - w(:,:,:,:,:,:,:)
  call sp1(w,w,nr1,nr2,nr3,nat,norm2)
  write(6,'("Norm of the difference between old and new force-constants:",&
       &     F25.20)') SQRT(norm2)
  !
  ! Check projection
  !
  !write(6,'("Check projection IFC")')
  !do l=1,m
  !  call sp2(frc_new,v(l,:),ind_v(l,:,:),nr1,nr2,nr3,nat,scal)
  !  if (DABS(scal).gt.1d-10) write(6,'("l= ",I8," frc_new|v(l)= ",F15.10)') l,scal
  !enddo
  !do k=1,p
  !  x(:,:,:,:,:,:,:)=u(k) % vec (:,:,:,:,:,:,:)
  !  call sp1(x,frc_new,nr1,nr2,nr3,nat,scal)
  !  if (DABS(scal).gt.1d-10) write(6,'("k= ",I8," frc_new|u(k)= ",F15.10)') k,scal
  !  deallocate(u(k) % vec)
  !enddo
  !
  do i=1,3
     do j=1,3
        do na=1,nat
           do nb=1,nat
              do n1=1,nr1
                 do n2=1,nr2
                    do n3=1,nr3
                       frc(n1,n2,n3,i,j,na,nb)=frc_new(n1,n2,n3,i,j,na,nb)
                    enddo
                 enddo
              enddo
           enddo
        enddo
     enddo
  enddo
  deallocate (x, w)
  deallocate (v, ind_v)
  deallocate (frc_new)
  !
  return
end subroutine set_asr
!
!----------------------------------------------------------------------
subroutine sp_zeu(zeu_u,zeu_v,nat,scal)
  !-----------------------------------------------------------------------
  !
  ! does the scalar product of two effective charges matrices zeu_u and zeu_v 
  ! (considered as vectors in the R^(3*3*nat) space, and coded in the usual way)
  !
  USE kinds, ONLY: DP
  implicit none
  integer i,j,na,nat
  real(DP) zeu_u(3,3,nat)
  real(DP) zeu_v(3,3,nat)
  real(DP) scal  
  !
  !
  scal=0.0d0
  do i=1,3
    do j=1,3
      do na=1,nat
        scal=scal+zeu_u(i,j,na)*zeu_v(i,j,na)
      enddo
    enddo
  enddo
  !
  return
  !
end subroutine sp_zeu
!
!
!----------------------------------------------------------------------
subroutine sp1(u,v,nr1,nr2,nr3,nat,scal)
  !-----------------------------------------------------------------------
  !
  ! does the scalar product of two force-constants matrices u and v (considered as
  ! vectors in the R^(3*3*nat*nat*nr1*nr2*nr3) space, and coded in the usual way)
  !
  USE kinds, ONLY: DP
  implicit none
  integer nr1,nr2,nr3,i,j,na,nb,n1,n2,n3,nat
  real(DP) u(nr1,nr2,nr3,3,3,nat,nat)
  real(DP) v(nr1,nr2,nr3,3,3,nat,nat)
  real(DP) scal  
  !
  !
  scal=0.0d0
  do i=1,3
    do j=1,3
      do na=1,nat
        do nb=1,nat
          do n1=1,nr1
            do n2=1,nr2
              do n3=1,nr3
                scal=scal+u(n1,n2,n3,i,j,na,nb)*v(n1,n2,n3,i,j,na,nb)
              enddo
            enddo
          enddo
        enddo
      enddo
    enddo
  enddo
  !
  return
  !
end subroutine sp1
!
!----------------------------------------------------------------------
subroutine sp2(u,v,ind_v,nr1,nr2,nr3,nat,scal)
  !-----------------------------------------------------------------------
  !
  ! does the scalar product of two force-constants matrices u and v (considered as
  ! vectors in the R^(3*3*nat*nat*nr1*nr2*nr3) space). u is coded in the usual way
  ! but v is coded as explained when defining the vectors corresponding to the 
  ! symmetry constraints
  !
  USE kinds, ONLY: DP
  implicit none
  integer nr1,nr2,nr3,i,nat
  real(DP) u(nr1,nr2,nr3,3,3,nat,nat)
  integer ind_v(2,7)
  real(DP) v(2)
  real(DP) scal  
  !
  !
  scal=0.0d0
  do i=1,2
    scal=scal+u(ind_v(i,1),ind_v(i,2),ind_v(i,3),ind_v(i,4),ind_v(i,5),ind_v(i,6), &
         ind_v(i,7))*v(i)
  enddo
  !
  return
  !
end subroutine sp2
!
!----------------------------------------------------------------------
subroutine sp3(u,v,i,na,nr1,nr2,nr3,nat,scal)
  !-----------------------------------------------------------------------
  !
  ! like sp1, but in the particular case when u is one of the u(k)%vec
  ! defined in set_asr (before orthonormalization). In this case most of the
  ! terms are zero (the ones that are not are characterized by i and na), so 
  ! that a lot of computer time can be saved (during Gram-Schmidt). 
  !
  USE kinds, ONLY: DP
  implicit none
  integer nr1,nr2,nr3,i,j,na,nb,n1,n2,n3,nat
  real(DP) u(nr1,nr2,nr3,3,3,nat,nat)
  real(DP) v(nr1,nr2,nr3,3,3,nat,nat)
  real(DP) scal  
  !
  !
  scal=0.0d0
  do j=1,3
    do nb=1,nat
      do n1=1,nr1
        do n2=1,nr2
          do n3=1,nr3
            scal=scal+u(n1,n2,n3,i,j,na,nb)*v(n1,n2,n3,i,j,na,nb)
          enddo
        enddo
      enddo
    enddo
  enddo
  !
  return
  !
end subroutine sp3
!
!-----------------------------------------------------------------------
SUBROUTINE q_gen(nsc,qbid,at_blk,bg_blk,at,bg)
  !-----------------------------------------------------------------------
  ! generate list of q (qbid) that are G-vectors of the supercell
  ! but not of the bulk
  !
  USE kinds,      ONLY : DP
  !
  IMPLICIT NONE
  INTEGER :: nsc
  REAL(DP) qbid(3,nsc), at_blk(3,3), bg_blk(3,3), at(3,3), bg(3,3)
  !
  INTEGER, PARAMETER:: nr1=4, nr2=4, nr3=4, &
                       nrm=(2*nr1+1)*(2*nr2+1)*(2*nr3+1)
  REAL(DP), PARAMETER:: eps=1.0d-7
  INTEGER :: i, j, k,i1, i2, i3, idum(nrm), iq
  REAL(DP) :: qnorm(nrm), qbd(3,nrm) ,qwork(3), delta
  LOGICAL lbho
  !
  i = 0
  DO i1=-nr1,nr1
     DO i2=-nr2,nr2
        DO i3=-nr3,nr3
           i = i + 1
           DO j=1,3
              qwork(j) = i1*bg(j,1) + i2*bg(j,2) + i3*bg(j,3)
           END DO ! j
           !
           qnorm(i)  = qwork(1)**2 + qwork(2)**2 + qwork(3)**2
           !
           DO j=1,3
              !
              qbd(j,i) = at_blk(1,j)*qwork(1) + &
                         at_blk(2,j)*qwork(2) + &
                         at_blk(3,j)*qwork(3)
           END DO ! j
           !
           idum(i) = 1
           !
        END DO ! i3
     END DO ! i2
  END DO ! i1
  !
  DO i=1,nrm-1
     IF (idum(i).EQ.1) THEN
        DO j=i+1,nrm
           IF (idum(j).EQ.1) THEN
              lbho=.TRUE.
              DO k=1,3
                 delta = qbd(k,i)-qbd(k,j)
                 lbho = lbho.AND. (ABS(NINT(delta)-delta).LT.eps)
              END DO ! k
              IF (lbho) THEN
                 IF(qnorm(i).GT.qnorm(j)) THEN
                    qbd(1,i) = qbd(1,j)
                    qbd(2,i) = qbd(2,j)
                    qbd(3,i) = qbd(3,j)
                    qnorm(i) = qnorm(j)
                 END IF
                 idum(j) = 0
              END IF
           END IF
        END DO ! j
     END IF
  END DO ! i
  !
  iq = 0
  DO i=1,nrm
     IF (idum(i).EQ.1) THEN
        iq=iq+1
        qbid(1,iq)= bg_blk(1,1)*qbd(1,i) +  &
                    bg_blk(1,2)*qbd(2,i) +  &
                    bg_blk(1,3)*qbd(3,i)
        qbid(2,iq)= bg_blk(2,1)*qbd(1,i) +  &
                    bg_blk(2,2)*qbd(2,i) +  &
                    bg_blk(2,3)*qbd(3,i)
        qbid(3,iq)= bg_blk(3,1)*qbd(1,i) +  &
                    bg_blk(3,2)*qbd(2,i) +  &
                    bg_blk(3,3)*qbd(3,i)
     END IF
  END DO ! i
  !
  IF (iq.NE.nsc) CALL errore('q_gen',' probably nr1,nr2,nr3 too small ', iq)
  RETURN
END SUBROUTINE q_gen
!
!-----------------------------------------------------------------------
SUBROUTINE check_at(at,bg_blk,alat,omega)
  !-----------------------------------------------------------------------
  !
  USE kinds,      ONLY : DP
  !
  IMPLICIT NONE
  !
  REAL(DP) :: at(3,3), bg_blk(3,3), alat, omega
  REAL(DP) :: work(3,3)
  INTEGER :: i,j
  REAL(DP), PARAMETER :: small=1.d-6
  !
  work(:,:) = at(:,:)
  CALL cryst_to_cart(3,work,bg_blk,-1)
  !
  DO j=1,3
     DO i =1,3
        IF ( ABS(work(i,j)-NINT(work(i,j))) > small) THEN
           WRITE (*,'(3f9.4)') work(:,:)
           CALL errore ('check_at','at not multiple of at_blk',1)
        END IF
     END DO
  END DO
  !
  omega =alat**3 * ABS(at(1,1)*(at(2,2)*at(3,3)-at(3,2)*at(2,3))- &
                       at(1,2)*(at(2,1)*at(3,3)-at(2,3)*at(3,1))+ &
                       at(1,3)*(at(2,1)*at(3,2)-at(2,2)*at(3,1)))
  !
  RETURN
END SUBROUTINE check_at
!
!-----------------------------------------------------------------------
SUBROUTINE set_tau (nat, nat_blk, at, at_blk, tau, tau_blk, &
     ityp, ityp_blk, itau_blk)
  !-----------------------------------------------------------------------
  !
  USE kinds,      ONLY : DP
  !
  IMPLICIT NONE
  INTEGER nat, nat_blk,ityp(nat),ityp_blk(nat_blk), itau_blk(nat)
  REAL(DP) at(3,3),at_blk(3,3),tau(3,nat),tau_blk(3,nat_blk)
  !
  REAL(DP) bg(3,3), r(3) ! work vectors
  INTEGER i,i1,i2,i3,na,na_blk
  REAL(DP) small
  INTEGER NN1,NN2,NN3
  PARAMETER (NN1=8, NN2=8, NN3=8, small=1.d-8)
  !
  CALL recips (at(1,1),at(1,2),at(1,3),bg(1,1),bg(1,2),bg(1,3))
  !
  na = 0
  !
  DO i1 = -NN1,NN1
     DO i2 = -NN2,NN2
        DO i3 = -NN3,NN3
           r(1) = i1*at_blk(1,1) + i2*at_blk(1,2) + i3*at_blk(1,3)
           r(2) = i1*at_blk(2,1) + i2*at_blk(2,2) + i3*at_blk(2,3)
           r(3) = i1*at_blk(3,1) + i2*at_blk(3,2) + i3*at_blk(3,3)
           CALL cryst_to_cart(1,r,bg,-1)
           !
           IF ( r(1).GT.-small .AND. r(1).LT.1.d0-small .AND.          &
                r(2).GT.-small .AND. r(2).LT.1.d0-small .AND.          &
                r(3).GT.-small .AND. r(3).LT.1.d0-small ) THEN
              CALL cryst_to_cart(1,r,at,+1)
              !
              DO na_blk=1, nat_blk
                 na = na + 1
                 IF (na.GT.nat) CALL errore('set_tau','too many atoms',na)
                 tau(1,na)    = tau_blk(1,na_blk) + r(1)
                 tau(2,na)    = tau_blk(2,na_blk) + r(2)
                 tau(3,na)    = tau_blk(3,na_blk) + r(3)
                 ityp(na)     = ityp_blk(na_blk)
                 itau_blk(na) = na_blk
              END DO
              !
           END IF
           !
        END DO
     END DO
  END DO
  !
  IF (na.NE.nat) CALL errore('set_tau','too few atoms: increase NNs',na)
  !
  RETURN
END SUBROUTINE set_tau
!
!-----------------------------------------------------------------------
SUBROUTINE read_tau &
     (nat, nat_blk, ntyp, bg_blk, tau, tau_blk, ityp, itau_blk)
  !---------------------------------------------------------------------
  !
  USE kinds,      ONLY : DP
  !
  IMPLICIT NONE
  !
  INTEGER nat, nat_blk, ntyp, ityp(nat),itau_blk(nat)
  REAL(DP) bg_blk(3,3),tau(3,nat),tau_blk(3,nat_blk)
  !
  REAL(DP) r(3) ! work vectors
  INTEGER i,na,na_blk
  !
  REAL(DP) small
  PARAMETER ( small = 1.d-6 )
  !
  DO na=1,nat
     READ(*,*) (tau(i,na),i=1,3), ityp(na)
     IF (ityp(na).LE.0 .OR. ityp(na) .GT. ntyp) &
          CALL errore('read_tau',' wrong atomic type', na)
     DO na_blk=1,nat_blk
        r(1) = tau(1,na) - tau_blk(1,na_blk)
        r(2) = tau(2,na) - tau_blk(2,na_blk)
        r(3) = tau(3,na) - tau_blk(3,na_blk)
        CALL cryst_to_cart(1,r,bg_blk,-1)
        IF (ABS( r(1)-NINT(r(1)) ) .LT. small .AND.                 &
            ABS( r(2)-NINT(r(2)) ) .LT. small .AND.                 &
            ABS( r(3)-NINT(r(3)) ) .LT. small ) THEN
           itau_blk(na) = na_blk
           go to 999
        END IF
     END DO
     CALL errore ('read_tau',' wrong atomic position ', na)
999  CONTINUE
  END DO
  !
  RETURN
END SUBROUTINE read_tau
!
!-----------------------------------------------------------------------
SUBROUTINE write_tau(fltau,nat,tau,ityp)
  !-----------------------------------------------------------------------
  !
  USE kinds,      ONLY : DP
  !
  IMPLICIT NONE
  !
  INTEGER nat, ityp(nat)
  REAL(DP) tau(3,nat)
  CHARACTER(LEN=*) fltau
  !
  INTEGER i,na
  !
  OPEN (unit=4,file=fltau, status='new')
  DO na=1,nat
     WRITE(4,'(3(f12.6),i3)') (tau(i,na),i=1,3), ityp(na)
  END DO
  CLOSE (4)
  !
  RETURN 
END SUBROUTINE write_tau
!
!-----------------------------------------------------------------------
SUBROUTINE gen_qpoints (ibrav, at, bg, nat, tau, ityp, nk1, nk2, nk3, &
     symm_type, ntetra, nqx, nq, q, tetra)
  !-----------------------------------------------------------------------
  !
  USE kinds,      ONLY : DP
  !
  IMPLICIT NONE
  ! input 
  INTEGER :: ibrav, nat, nk1, nk2, nk3, ntetra, ityp(*)
  REAL(DP) :: at(3,3), bg(3,3), tau(3,nat)
  character(LEN=9)    :: symm_type
  ! output 
  INTEGER :: nqx, nq, tetra(4,ntetra)
  REAL(DP) :: q(3,nqx)
  ! local
  INTEGER :: nrot, nsym, s(3,3,48), ftau(3,48), irt(48,nat)
  INTEGER :: t_rev(48) = 0
  LOGICAL :: minus_q, invsym, time_reversal = .TRUE.
  REAL(DP) :: xqq(3), wk(nqx), mdum(3,nat)
  CHARACTER(LEN=45)   ::  sname(48)
  !
  xqq (:) =0.d0
  IF (ibrav == 4 .OR. ibrav == 5) THEN  
     !
     !  hexagonal or trigonal bravais lattice
     !
     CALL hexsym (at, s, sname, nrot)  
  ELSEIF (ibrav >= 1 .AND. ibrav <= 14) THEN  
     !
     !  cubic bravais lattice
     !
     CALL cubicsym (at, s, sname, nrot)  
  ELSEIF (ibrav == 0) THEN  

     if (symm_type=='cubic') then
        CALL cubicsym (at, s, sname, nrot)  
     elseif (symm_type=='hexagonal') then
        CALL hexsym (at, s, sname, nrot)  
     else
        CALL infomsg ('gen_qpoints', 'symm_type missing: assuming cubic symmetry')  
        CALL cubicsym (at, s, sname, nrot)  
     end if

  ELSE  
     CALL errore ('gen_qpoints', 'wrong ibrav', 1)  
  ENDIF
  !
  CALL kpoint_grid ( nrot, time_reversal, s, t_rev, bg, nqx, &
                           0,0,0, nk1,nk2,nk3, nq, q, wk)
  !
  CALL sgama (nrot, nat, s, sname, t_rev, at, bg, tau, ityp, nsym, &
              6,6,6, irt, ftau, nqx, nq, q, wk, invsym, minus_q, xqq, &
              0, time_reversal, .NOT.time_reversal, mdum)
  !
  IF (ntetra /= 6 * nk1 * nk2 * nk3) &
       CALL errore ('gen_qpoints','inconsistent ntetra',1)
  !
  CALL tetrahedra (nsym, s, minus_q, at, bg, nqx, 0, 0, 0, &
       nk1, nk2, nk3, nq, q, wk, ntetra, tetra)
  !
  RETURN
END SUBROUTINE gen_qpoints
!
!---------------------------------------------------------------------
SUBROUTINE a2Fdos &
     (nat, nq, nr1, nr2, nr3, ibrav, at, bg, tau, alat, &
     nsc, nat_blk, at_blk, bg_blk, itau_blk, omega_blk, rws, nrws, &
     dos, Emin, DeltaE, ndos, ntetra, tetra, asr, q, freq )
  !-----------------------------------------------------------------------
  !
  USE kinds,      ONLY : DP
  USE ifconstants
  USE constants,  ONLY : pi
  !
  IMPLICIT NONE
  !
  INTEGER, INTENT(in) :: nat, nq, nr1, nr2, nr3, ibrav, ndos, ntetra, &
       tetra(4, ntetra)
  LOGICAL, INTENT(in) :: dos
  CHARACTER(LEN=*), INTENT(IN) :: asr
  REAL(DP), INTENT(in) :: freq(3*nat,nq), q(3,nq), at(3,3), bg(3,3), &
       tau(3,nat), alat, Emin, DeltaE
  !
  INTEGER, INTENT(in) :: nsc, nat_blk, itau_blk, nrws
  REAL(DP), INTENT(in) :: rws(0:3,nrws), at_blk(3,3), bg_blk(3,3), omega_blk
  !
  REAL(DP), ALLOCATABLE    :: gamma(:,:), frcg(:,:,:,:,:,:,:)
  COMPLEX(DP), ALLOCATABLE :: gam(:,:,:,:), gam_blk(:,:,:,:), z(:,:)

  real(DP)                 :: lambda, dos_a2F(50), temp, dos_ee(10), dos_tot, &
                              deg(10), fermi(10), E
  real(DP), parameter      :: rydTHz = 3289.828d0, eps_w2 = 0.0000001d0 
  integer                  :: isig, ifn, n, m, na, nb, nc, nu, nmodes, &
                              i,j,k, ngauss, jsig, p1, p2, p3, filea2F
  character(len=14)        :: name
  !
  !
  nmodes = 3*nat
  do isig=1,10
     filea2F = 60 + isig
     write(name,"(A10,I2)") 'a2Fmatdyn.',filea2F
     open(filea2F, file=name, STATUS = 'unknown')
     READ(filea2F,*) deg(isig), fermi(isig), dos_ee(isig)
  enddo
  !
  IF(dos) then
     open(400,file='lambda',status='unknown')
     write(400,*)
     write(400,*) ' Electron-phonon coupling constant, lambda '
     write(400,*)
  ELSE
     open (20,file='gam.lines' ,status='unknown')
     write(20,*) 
     write(20,*) ' Gamma lines for all modes [THz] '
     write(20,*)
     write(6,*)
     write(6,*) ' Gamma lines for all modes [Rydberg] '
     write(6,*)
  ENDIF
  !
  ALLOCATE ( frcg(nr1,nr2,nr3,3,3,nat,nat) )
  ALLOCATE ( gamma(3*nat,nq), gam(3,3,nat,nat), gam_blk(3,3,nat_blk,nat_blk) )
  ALLOCATE ( z(3*nat,3*nat) )
  !
  frcg(:,:,:,:,:,:,:) = 0.d0
  DO isig = 1, 10
     filea2F = 60 + isig 
     CALL readfg ( filea2F, nr1, nr2, nr3, nat, frcg )
     !
     if ( asr /= 'no') then
        CALL set_asr (asr, nr1, nr2, nr3, frcg, zeu, nat_blk, ibrav, tau_blk)
     endif
     !
     open(300,file='dyna2F',status='old')
     !
     do n = 1 ,nq
        gam(:,:,:,:) = (0.d0, 0.d0)
        read(300,*)
        do na=1,nmodes
           read(300,*) (z(na,m),m=1,nmodes)
        end do ! na
        !
        CALL setgam (q(1,n), gam, nat, at, bg, tau, itau_blk, nsc, alat, &
             gam_blk, nat_blk, at_blk,bg_blk,tau_blk, omega_blk, &
             frcg, nr1,nr2,nr3, rws, nrws)
        !
        ! here multiply dyn*gam*dyn for gamma and divide by w2 for lambda at given q
        !
        do nc = 1, nat
           do k =1, 3
              p1 = (nc-1)*3+k
              nu = p1
              gamma(nu,n) = 0.0d0
              do i=1,3
                 do na=1,nat
                    p2 = (na-1)*3+i
                    do j=1,3
                       do nb=1,nat
                          p3 = (nb-1)*3+j
                          gamma(nu,n) = gamma(nu,n) + DBLE(conjg(z(p2,p1)) * &
                               gam(i,j,na,nb) * z(p3,p1))
                       enddo  ! nb
                    enddo  ! j
                 enddo  ! na
              enddo  !i
              gamma(nu,n) = gamma(nu,n) * pi / 2.0d0
           enddo  ! k
        enddo  !nc
        !
        !
     EndDo !nq    all points in BZ
     close(300)   ! file with dyn vectors
     !
     ! after we know gamma(q) and lambda(q) calculate  DOS(omega) for spectrum a2F
     !
     if(dos) then
        ! 
        if(isig.le.9) then
           write(name,'(A8,I1.1)') 'a2F.dos.',isig
        else
           write(name,'(A8,I2.2)') 'a2F.dos.',isig
        endif
        ifn = 200 + isig
        open (ifn,file=name,status='unknown',form='formatted')
        write(ifn,*)
        write(ifn,*) ' Eliashberg function a2F (per both spin)'
        write(ifn,*) '  frequencies in Rydberg  '
        write(ifn,*) ' DOS normalized to E in Rydberg: a2F_total, a2F(mode) '
        write(ifn,*)
        !
        !      correction for small frequencies
        !
        do n = 1, nq
           do i = 1, nmodes 
              if (freq(i,n).LE.eps_w2) then
                 gamma(i,n) = 0.0d0                 
              endif
           enddo
        enddo
        !
        lambda = 0.0d0
        do n= 1, ndos
           !
           E = Emin + (n-1)*DeltaE + 0.5d0*DeltaE
           dos_tot = 0.0d0 
           do j=1,nmodes
              !
              dos_a2F(j) = 0.0d0
              CALL dos_gam(nmodes, nq, j, ntetra, tetra, &
                   gamma, freq, E, dos_a2F(j))
              dos_a2F(j) = dos_a2F(j) / dos_ee(isig) / 2.d0 / pi
              dos_tot = dos_tot + dos_a2F(j)
              !
           enddo
           lambda = lambda + 2.d0 * dos_tot/E * DeltaE 
           write (ifn, 1050) E, dos_tot, (dos_a2F(j),j=1,nmodes)
        enddo  !ndos
        write(ifn,*) " lambda =",lambda,'   Delta = ',DeltaE
        close (ifn)
        write(400,'(" Broadening ",F8.4," lambda ",F12.4," dos_el ",F8.4)') &
             deg(isig),lambda, dos_ee(isig)
        !
     endif !dos
     !
     !  OUTPUT
     !
     if(.not.dos) then
        write(20,'(" Broadening ",F8.4)')  deg(isig)
        write(6,'(" Broadening ",F8.4)')  deg(isig)
        do n=1, nq
           write(20,1030) n,(gamma(i,n)*rydTHz,i=1,3*nat)
           write(6,1040) n, (gamma(i,n),i=1,3*nat)
        end do
     endif
     !
  ENDDO !isig
  !
  DEALLOCATE (z, frcg, gamma, gam, gam_blk )
  !
  close(400)   !lambda
  close(20)
  !
1030 FORMAT( 3x,I5,'  ',9F8.4 )
1040 FORMAT( 3x,I5,'  ',6F12.9 )
1050 FORMAT( 3x,F12.6,6F16.8 )
  !
  RETURN
END SUBROUTINE a2Fdos
!
!-----------------------------------------------------------------------
subroutine setgam (q, gam, nat, at,bg,tau,itau_blk,nsc,alat, &
     &             gam_blk, nat_blk,    at_blk,bg_blk,tau_blk,omega_blk, &
     &             frcg, nr1,nr2,nr3, rws,nrws)
  !-----------------------------------------------------------------------
  ! compute the dynamical matrix (the analytic part only)
  !
  USE kinds,       ONLY : DP
  USE constants,   ONLY : tpi
  implicit none
  !
  ! I/O variables
  !
  integer        :: nr1, nr2, nr3, nat, nat_blk,  &
                    nsc, nrws, itau_blk(nat)
  real(DP)       :: q(3), tau(3,nat), at(3,3), bg(3,3), alat, rws(0:3,nrws)
  real(DP)       :: tau_blk(3,nat_blk), at_blk(3,3), bg_blk(3,3), omega_blk, &
                    frcg(nr1,nr2,nr3,3,3,nat_blk,nat_blk)
  COMPLEX(DP)  :: gam_blk(3,3,nat_blk,nat_blk)
  COMPLEX(DP) ::  gam(3,3,nat,nat)
  !
  ! local variables
  !
  real(DP)        :: arg
  complex(DP)     :: cfac(nat)
  integer         :: i,j,k, na,nb, na_blk, nb_blk, iq
  real(DP)        :: qp(3), qbid(3,nsc) ! automatic array
  !
  !
  call q_gen(nsc,qbid,at_blk,bg_blk,at,bg)
  !
  do iq=1,nsc
     !
     do k=1,3
        qp(k)= q(k) + qbid(k,iq)
     end do
     !
     gam_blk(:,:,:,:) = (0.d0,0.d0)
     CALL frc_blk (gam_blk,qp,tau_blk,nat_blk,              &
                   nr1,nr2,nr3,frcg,at_blk,bg_blk,rws,nrws)
     !
     do na=1,nat
        na_blk = itau_blk(na)
        do nb=1,nat
           nb_blk = itau_blk(nb)
           !
           arg = tpi * ( qp(1) * ( (tau(1,na)-tau_blk(1,na_blk)) -   &
                                (tau(1,nb)-tau_blk(1,nb_blk)) ) + &
                      qp(2) * ( (tau(2,na)-tau_blk(2,na_blk)) -   &
                                (tau(2,nb)-tau_blk(2,nb_blk)) ) + &
                      qp(3) * ( (tau(3,na)-tau_blk(3,na_blk)) -   &
                                (tau(3,nb)-tau_blk(3,nb_blk)) ) )
           !
           cfac(nb) = cmplx(cos(arg),sin(arg))/nsc
           !
        end do ! nb
        do nb=1,nat
           do i=1,3
              do j=1,3
                 nb_blk = itau_blk(nb)
                 gam(i,j,na,nb) = gam(i,j,na,nb) + cfac(nb) * &
                     gam_blk(i,j,na_blk,nb_blk)
              end do ! j
              end do ! i 
        end do ! nb
     end do ! na
     !
  end do ! iq
  !
  return
end subroutine setgam
!
!--------------------------------------------------------------------
subroutine dos_gam (nbndx, nq, jbnd, ntetra, &
                    tetra, gamma, et, ef, dos_a2F)
  !--------------------------------------------------------------------
  ! calculates weights with the tetrahedron method (Bloechl version)
  ! this subroutine is based on tweights.f90 belonging to PW 
  ! it calculates a2F on the surface of given frequency <=> histogram
  ! Band index means the frequency mode here 
  ! and "et" means the frequency(mode,q-point)
  !
  USE kinds,       ONLY: DP
  use parameters
!  USE ifconstants, ONLY : gamma
  implicit none
  !
  integer :: nq, nbndx, ntetra, tetra(4,ntetra), jbnd
  real(DP) :: et(nbndx,nq), gamma(nbndx,nq), func
  
  real(DP) :: ef, dos_a2F
  real(DP) :: e1, e2, e3, e4, c1, c2, c3, c4, etetra(4)
  integer      :: ik, ibnd, nt, nk, ns, i, ik1, ik2, ik3, ik4, itetra(4)

  real(DP) ::   f12,f13,f14,f23,f24,f34, f21,f31,f41,f42,f32,f43
  real(DP) ::   P1,P2,P3,P4, G, Z, o13, Y1,Y2,Y3,Y4, WW, eps,vol, Tint


      Tint = 0.0d0
      eps  = 1.0d-14
      vol  = 1.0d0/ntetra

     do nt = 1, ntetra
         ibnd = jbnd
           !
           ! etetra are the energies at the vertexes of the nt-th tetrahedron
           !
           do i = 1, 4
              etetra(i) = et(ibnd, tetra(i,nt))
           enddo
           itetra(1) = 0
           call hpsort (4,etetra,itetra)
           !
           ! ...sort in ascending order: e1 < e2 < e3 < e4
           !
           e1 = etetra (1)
           e2 = etetra (2)
           e3 = etetra (3)
           e4 = etetra (4)
           !
           ! kp1-kp4 are the irreducible k-points corresponding to e1-e4
           !
           ik1 = tetra(itetra(1),nt)
           ik2 = tetra(itetra(2),nt)
           ik3 = tetra(itetra(3),nt)
           ik4 = tetra(itetra(4),nt)
           Y1  = gamma(ibnd,ik1)/et(ibnd,ik1)
           Y2  = gamma(ibnd,ik2)/et(ibnd,ik2)
           Y3  = gamma(ibnd,ik3)/et(ibnd,ik3)
           Y4  = gamma(ibnd,ik4)/et(ibnd,ik4)


           f12 = (ef-e2)/(e1-e2)
           f13 = (ef-e3)/(e1-e3)
           f14 = (ef-e4)/(e1-e4)
           f23 = (ef-e3)/(e2-e3)
           f24 = (ef-e4)/(e2-e4)
           f34 = (ef-e4)/(e3-e4)

           f21 = 1.0d0 - f12
           f31 = 1.0d0 - f13
           f41 = 1.0d0 - f14
           f32 = 1.0d0 - f23
           f42 = 1.0d0 - f24
           f43 = 1.0d0 - f34

           o13 = 1.0d0/3.0d0
           G   = 0.0d0
           P1  = 0.0d0
           P2  = 0.0d0
           P3  = 0.0d0
           P4  = 0.0d0

           IF(e1.gt.ef.or.e4.lt.ef) then
                 goto 500
           ENDIF

       IF(e3.lt.ef.and.ef.lt.e4) THEN

         Z  =  (1.0d0 - f14 * f24 * f34)
         G  =  3.0d0 * (1.0d0 - Z) / (e4-ef)
         P1 =  f14 * o13
         P2 =  f24 * o13
         P3 =  f34 * o13
         P4 =  (f41 + f42 + f43) * o13
         goto 200

       ENDIF


       IF(e2.lt.ef.and.ef.lt.e3) THEN

         G   =  3.0d0 * (f23*f31 + f32*f24)
         P1  =  f14 * o13 + f13*f31*f23 / G
         P2  =  f23 * o13 + f24*f24*f32 / G
         P3  =  f32 * o13 + f31*f31*f23 / G
         P4  =  f41 * o13 + f42*f24*f32 / G
         G   =  G / (e4-e1)
         goto 200

       ENDIF


       IF(e1.lt.ef.and.ef.lt.e2) THEN

         Z  =  f21 * f31 * f41
         G  =  3.0d0 * Z / (ef-e1)
         P1 =  o13 * (f12 + f12 + f14)
         P2 =  o13 * f21
         P3 =  o13 * f31
         P4 =  o13 * f41
         goto 200

       ENDIF

200      WW = G * (Y1*P1 + Y2*P2 + Y3*P3 + Y4*P4)

         Tint = Tint + WW * vol

500     continue
     enddo   ! ntetra


  dos_a2F = Tint  !2 because DOS_ee is per 1 spin

  return
end subroutine dos_gam
!
!
!-----------------------------------------------------------------------
subroutine readfg ( ifn, nr1, nr2, nr3, nat, frcg )
  !-----------------------------------------------------------------------
  !
  USE kinds,       ONLY : DP
  implicit none
  ! I/O variable
  integer, intent(in) ::  nr1,nr2,nr3, nat
  real(DP), intent(out) :: frcg(nr1,nr2,nr3,3,3,nat,nat)
  ! local variables
  integer i, j, na, nb, m1,m2,m3, ifn
  integer ibid, jbid, nabid, nbbid, m1bid,m2bid,m3bid
  !
  !
  READ (ifn,*) m1, m2, m3
  if ( m1 /= nr1 .or. m2 /= nr2 .or. m3 /= nr3) &
       call errore('readfG','inconsistent nr1, nr2, nr3 read',1)
  do i=1,3
     do j=1,3
        do na=1,nat
           do nb=1,nat
              read (ifn,*) ibid, jbid, nabid, nbbid
              if(i.ne.ibid.or.j.ne.jbid.or.na.ne.nabid.or.nb.ne.nbbid)  then
                  write(*,*) i,j,na,nb,'  <>  ', ibid, jbid, nabid, nbbid 
                  call errore  ('readfG','error in reading',1)
              else
                  read (ifn,*) (((m1bid, m2bid, m3bid,     &
                                 frcg(m1,m2,m3,i,j,na,nb), &
                                 m1=1,nr1),m2=1,nr2),m3=1,nr3)
              endif
           end do
        end do
     end do
  end do
  !
  close(ifn)
  !
  return
end subroutine readfg
