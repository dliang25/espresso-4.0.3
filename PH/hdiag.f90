!
! Copyright (C) 2001 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
!-----------------------------------------------------------------------
subroutine hdiag( max_iter, avg_iter, xk_, et_ )
  !
  ! Diagonalizes the unperturbed Hamiltonian in a non-selfconsistent way
  ! by Conjugate Gradient (band-by-band)
  !
#include "f_defs.h"
  USE kinds,     ONLY : DP
  USE cell_base, ONLY: tpiba2
  USE gvect,     ONLY: g, ecfixed, qcutz, q2sigma, gstart
  USE wvfct,     ONLY: g2kin, igk, nbnd, npwx, npw
  USE uspp,      ONLY: vkb, okvan
  USE noncollin_module,    ONLY: npol
  USE wavefunctions_module,ONLY: evc
  USE ramanm,    ONLY: eth_ns
  implicit none

  !
  !     I/O variables:
  !
  integer :: max_iter
  ! maximum number of iterations
  real(DP) :: avg_iter, xk_(3), et_(nbnd)
  ! iteration number in the diagonalization
  ! k-point
  ! eigenvalues of the diagonalization
  !
  !     Local variables:
  !
  REAL(DP) :: cg_iter
  ! number of iteration in CG
  REAL(DP), EXTERNAL :: erf
  ! error function
  INTEGER  :: ig, ntry, notconv
  ! counter on G vectors
  ! number or repeated call to diagonalization in case of non convergence
  ! number of notconverged elements
  INTEGER, ALLOCATABLE :: btype(:)
    ! type of band: valence (1) or conduction (0)  
  REAl(DP), ALLOCATABLE :: h_prec(:)
    ! preconditioning matrix (diagonal)

  call start_clock ('hdiag')

  allocate (h_prec( npwx), btype(nbnd))
  btype(:) = 1
  !
  !   various initializations
  !
  call init_us_2 (npw, igk, xk_, vkb)
  !
  !    sets the kinetic energy
  !
  do ig = 1, npw
     g2kin (ig) =((xk_ (1) + g (1, igk (ig) ) ) **2 + &
                  (xk_ (2) + g (2, igk (ig) ) ) **2 + &
                  (xk_ (3) + g (3, igk (ig) ) ) **2 ) * tpiba2
  enddo
  !
  !   if (qcutz > 0.d0) then
  !      do ig = 1, npw
  !         g2kin (ig) = g2kin (ig) + qcutz * (1.d0 + erf ( (g2kin (ig) &
  !              - ecfixed) / q2sigma) )
  !      enddo
  !   endif

  !
  ! Conjugate-Gradient diagonalization
  !
  h_prec=1.0_DP
  do ig = 1, npw
     h_prec (ig) = max (1.d0, g2kin (ig) )
  enddo
  ntry = 0
10 continue
  if (ntry > 0) then
     call rotate_wfc &
       ( npwx, npw, nbnd, gstart, nbnd, evc, npol, okvan, evc, et_ )
     avg_iter = avg_iter + 1.d0
  endif
  call ccgdiagg (npwx, npw, nbnd, npol, evc, et_, btype, h_prec, eth_ns, &
       max_iter, .true., notconv, cg_iter)
  avg_iter = avg_iter + cg_iter
  ntry = ntry + 1

  if (ntry.le.5.and.notconv.gt.0) goto 10

  deallocate (btype, h_prec)
  call stop_clock ('hdiag')

  return
end subroutine hdiag

