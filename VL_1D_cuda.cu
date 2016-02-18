/*! \file VL_1D_cuda.cu
 *  \brief Definitions of the cuda VL algorithm functions. */

#ifdef CUDA
#ifdef VL

#include<stdio.h>
#include<stdlib.h>
#include<math.h>
#include<cuda.h>
#include"global.h"
#include"global_cuda.h"
#include"VL_1D_cuda.h"
#include"pcm_cuda.h"
#include"plmp_vl_cuda.h"
#include"ppmp_vl_cuda.h"
#include"ppmc_vl_cuda.h"
#include"exact_cuda.h"
#include"roe_cuda.h"
#include"cooling_cuda.h"
#include"error_handling.h"
#include"io.h"



__global__ void Update_Conserved_Variables_1D_notime(Real *dev_conserved, Real *dev_conserved_half, Real *dev_F, int n_cells, int n_ghost, 
                                                     Real dx, Real dt, Real gamma);


__global__ void Update_Conserved_Variables_1D_wtime(Real *dev_conserved, Real *dev_F, int n_cells, int n_ghost, 
                                                    Real dx, Real dt, Real *dti_array, Real gamma);


Real VL_Algorithm_1D_CUDA(Real *host_conserved, int nx, int n_ghost, Real dx, Real dt)
{
  //Here, *host_conserved contains the entire
  //set of conserved variables on the grid

  int n_cells = nx;
  int ny = 1;
  int nz = 1;
  int n_fields;

  #ifdef DE
  printf("Dual energy not implemented in Van Leer integrator. Use CTU, or neither.\n");
  exit(0);
  #endif
  #ifndef DE
  n_fields = 5;
  #endif

  // set the dimensions of the cuda grid
  int  ngrid = (n_cells + TPB - 1) / TPB;
  dim3 dimGrid(ngrid, 1, 1);
  dim3 dimBlock(TPB, 1, 1);

  // allocate an array on the CPU to hold max_dti returned from each thread block
  Real max_dti = 0;
  Real *host_dti_array;
  host_dti_array = (Real *) malloc(ngrid*sizeof(Real));


  // allocate GPU arrays
  // conserved variables
  Real *dev_conserved, *dev_conserved_half;
  // initial input states and associated interface fluxes (Q* and F* from Stone, 2008)
  Real *Q_L, *Q_R, *F;
  // array to hold zero values for H correction (necessary to pass to Roe solver)
  Real *etah;
  // array of inverse timesteps for dt calculation
  Real *dev_dti_array;


  // allocate memory on the GPU
  CudaSafeCall( cudaMalloc((void**)&dev_conserved, n_fields*n_cells*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&dev_conserved_half, n_fields*n_cells*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&Q_L, n_fields*n_cells*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&Q_R, n_fields*n_cells*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&F,   n_fields*n_cells*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&etah, n_cells*sizeof(Real)) );
  CudaSafeCall( cudaMalloc((void**)&dev_dti_array, ngrid*sizeof(Real)) );

  // zero all the GPU arrays
  cudaMemset(dev_conserved, 0, n_fields*n_cells*sizeof(Real));
  cudaMemset(dev_conserved_half, 0, n_fields*n_cells*sizeof(Real));
  cudaMemset(Q_L, 0, n_fields*n_cells*sizeof(Real));
  cudaMemset(Q_R, 0, n_fields*n_cells*sizeof(Real));
  cudaMemset(F, 0, n_fields*n_cells*sizeof(Real));
  cudaMemset(etah, 0, n_cells*sizeof(Real));
  cudaMemset(dev_dti_array, 0, ngrid*sizeof(Real));
  CudaCheckError();


  // copy the conserved variable array onto the GPU

  CudaSafeCall( cudaMemcpy(dev_conserved, host_conserved, n_fields*n_cells*sizeof(Real), cudaMemcpyHostToDevice) );


  // Step 1: Use PCM reconstruction to put conserved variables into interface arrays
  PCM_Reconstruction_1D<<<dimGrid,dimBlock>>>(dev_conserved, Q_L, Q_R, nx, n_ghost, gama);
  CudaCheckError();

  // Step 2: Calculate first-order upwind fluxes 
  #ifdef EXACT
  Calculate_Exact_Fluxes<<<dimGrid,dimBlock>>>(Q_L, Q_R, F, nx, ny, nz, n_ghost, gama, 0);
  #endif
  #ifdef ROE
  Calculate_Roe_Fluxes<<<dimGrid,dimBlock>>>(Q_L, Q_R, F, nx, ny, nz, n_ghost, gama, etah, 0);
  #endif
  CudaCheckError();


  // Step 3: Update the conserved variables half a timestep 
  Update_Conserved_Variables_1D_notime<<<dimGrid,dimBlock>>>(dev_conserved, dev_conserved_half, F, n_cells, n_ghost, dx, 0.5*dt, gama);
  CudaCheckError();


  // Step 4: Construct left and right interface values using updated conserved variables
  #ifdef PCM
  PCM_Reconstruction_1D<<<dimGrid,dimBlock>>>(dev_conserved_half, Q_L, Q_R, nx, n_ghost, gama);
  #endif
  #ifdef PLMP
  PLMP_VL<<<dimGrid,dimBlock>>>(dev_conserved_half, Q_L, Q_R, nx, ny, nz, n_ghost, gama, 0);
  #endif
  #ifdef PPMP
  PPMP_VL<<<dimGrid,dimBlock>>>(dev_conserved_half, Q_L, Q_R, nx, ny, nz, n_ghost, gama, 0);
  #endif
  #ifdef PPMC
  PPMC_VL<<<dimGrid,dimBlock>>>(dev_conserved_half, Q_L, Q_R, nx, ny, nz, n_ghost, gama, 0);
  #endif
  CudaCheckError();


  // Step 5: Calculate the fluxes again
  #ifdef EXACT
  Calculate_Exact_Fluxes<<<dimGrid,dimBlock>>>(Q_L, Q_R, F, nx, ny, nz, n_ghost, gama, 0);
  #endif
  #ifdef ROE
  Calculate_Roe_Fluxes<<<dimGrid,dimBlock>>>(Q_L, Q_R, F, nx, ny, nz, n_ghost, gama, etah, 0);
  #endif
  CudaCheckError();


  // Step 6: Update the conserved variable array
  Update_Conserved_Variables_1D_wtime<<<dimGrid,dimBlock>>>(dev_conserved, F, n_cells, n_ghost, dx, dt, dev_dti_array, gama);
  CudaCheckError();
   

  // Apply cooling
  #ifdef COOLING_GPU
  cooling_kernel<<<dimGrid,dimBlock>>>(dev_conserved, nx, ny, nz, n_ghost, dt, gama);
  #endif


  // copy the conserved variable array back to the CPU
  CudaSafeCall( cudaMemcpy(host_conserved, dev_conserved, n_fields*n_cells*sizeof(Real), cudaMemcpyDeviceToHost) );

  // copy the dti array onto the CPU
  CudaSafeCall( cudaMemcpy(host_dti_array, dev_dti_array, ngrid*sizeof(Real), cudaMemcpyDeviceToHost) );
  // iterate through to find the maximum inverse dt for this subgrid block
  for (int i=0; i<ngrid; i++) {
    max_dti = fmax(max_dti, host_dti_array[i]);
  }


  // free the CPU memory
  free(host_dti_array);


  // free the GPU memory
  cudaFree(dev_conserved);
  cudaFree(dev_conserved_half);
  cudaFree(Q_L);
  cudaFree(Q_R);
  cudaFree(F);
  cudaFree(etah);


  // return the maximum inverse timestep
  return max_dti;


}


__global__ void Update_Conserved_Variables_1D_notime(Real *dev_conserved, Real *dev_conserved_half, Real *dev_F, int n_cells, int n_ghost, Real dx, Real dt, Real gamma)
{
  int id;
  Real dtodx = dt/dx;

  // get a global thread ID
  id = threadIdx.x + blockIdx.x * blockDim.x;

  // threads corresponding all cells except outer ring of ghost cells do the calculation
  if (id > 0 && id < n_cells-1)
  {
    // update the conserved variable array
    dev_conserved_half[            id] = dev_conserved[            id] + dtodx * (dev_F[            id-1] - dev_F[            id]);
    dev_conserved_half[  n_cells + id] = dev_conserved[  n_cells + id] + dtodx * (dev_F[  n_cells + id-1] - dev_F[  n_cells + id]);
    dev_conserved_half[2*n_cells + id] = dev_conserved[2*n_cells + id] + dtodx * (dev_F[2*n_cells + id-1] - dev_F[2*n_cells + id]);
    dev_conserved_half[3*n_cells + id] = dev_conserved[3*n_cells + id] + dtodx * (dev_F[3*n_cells + id-1] - dev_F[3*n_cells + id]);
    dev_conserved_half[4*n_cells + id] = dev_conserved[4*n_cells + id] + dtodx * (dev_F[4*n_cells + id-1] - dev_F[4*n_cells + id]);
  }


}


__global__ void Update_Conserved_Variables_1D_wtime(Real *dev_conserved, Real *dev_F, int n_cells, int n_ghost, Real dx, Real dt, Real *dti_array, Real gamma)
{
  __shared__ Real max_dti[TPB];

  Real d, d_inv, vx, vy, vz, P, cs;
  int id, tid;

  Real dtodx = dt/dx;

  // get a global thread ID
  id = threadIdx.x + blockIdx.x * blockDim.x;
  // and a thread id within the block
  tid = threadIdx.x;

  // set shared memory to 0
  max_dti[tid] = 0;
  __syncthreads();


  // threads corresponding to real cells do the calculation
  if (id > n_ghost - 1 && id < n_cells-n_ghost)
  {
    // update the conserved variable array
    dev_conserved[            id] += dtodx * (dev_F[            id-1] - dev_F[            id]);
    dev_conserved[  n_cells + id] += dtodx * (dev_F[  n_cells + id-1] - dev_F[  n_cells + id]);
    dev_conserved[2*n_cells + id] += dtodx * (dev_F[2*n_cells + id-1] - dev_F[2*n_cells + id]);
    dev_conserved[3*n_cells + id] += dtodx * (dev_F[3*n_cells + id-1] - dev_F[3*n_cells + id]);
    dev_conserved[4*n_cells + id] += dtodx * (dev_F[4*n_cells + id-1] - dev_F[4*n_cells + id]);

    if (dev_conserved[id] < 0.0 || dev_conserved[id] != dev_conserved[id]) printf("%d Thread creashed in final update. %f\n", id, dev_conserved[id]);

    // start timestep calculation here
    // every thread collects the conserved variables it needs from global memory
    d  =  dev_conserved[            id];
    d_inv = 1.0 / d;
    vx =  dev_conserved[1*n_cells + id] * d_inv;
    vy =  dev_conserved[2*n_cells + id] * d_inv;
    vz =  dev_conserved[3*n_cells + id] * d_inv;
    P  = (dev_conserved[4*n_cells + id] - 0.5*d*(vx*vx + vy*vy + vz*vz)) * (gamma - 1.0);
    if (P < 0.0) printf("%d Negative pressure after final update.\n", id);
    P  = fmax(P, (Real) 1.0e-20);
    // find the max wavespeed in that cell, use it to calculate the inverse timestep
    cs = sqrt(d_inv * gamma * P);
    max_dti[tid] = (fabs(vx)+cs)/dx;
  }
  __syncthreads();
  
  // do the reduction in shared memory (find the max inverse timestep in the block)
  for (unsigned int s=1; s<blockDim.x; s*=2) {
    if (tid % (2*s) == 0) {
      max_dti[tid] = fmax(max_dti[tid], max_dti[tid + s]);
    }
    __syncthreads();
  }

  // write the result for this block to global memory
  if (tid == 0) dti_array[blockIdx.x] = max_dti[0];


}

#endif //VL
#endif //CUDA
