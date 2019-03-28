/*
    Copyright 2019 Zheyong Fan
    This file is part of GPUGA.
    GPUGA is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUGA is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUGA.  If not, see <http://www.gnu.org/licenses/>.
*/


/*----------------------------------------------------------------------------80
Get the fitness
------------------------------------------------------------------------------*/


#include "fitness.cuh"
#include "neighbor.cuh"
#include "error.cuh"
#include "read_file.cuh"
#include "common.cuh"
#define BLOCK_SIZE 128


Fitness::Fitness(char* input_dir)
{
    read_xyz_in(input_dir);
    box.read_file(input_dir);
    neighbor.compute(Nc, N, Na, Na_sum, x, y, z, &box);
    
// test the force
initialize_potential(); // set up potential parameters
for (int n = 0; n < 10000; ++n) find_force();
double *cpu_fx;
MY_MALLOC(cpu_fx, double, N);
cudaMemcpy(cpu_fx, fx, sizeof(double)*N, cudaMemcpyDeviceToHost);
FILE* fid = my_fopen("f.out", "w");
for (int n = 0; n < N; ++n)
{
    fprintf(fid, "%20.10f\n", cpu_fx[n]);
}
cudaMemcpy(cpu_fx, fx_ref, sizeof(double)*N, cudaMemcpyDeviceToHost);
for (int n = 0; n < N; ++n)
{
    fprintf(fid, "%20.10f\n", cpu_fx[n]);
}
fclose(fid);
MY_FREE(cpu_fx);

}


Fitness::~Fitness(void)
{
    MY_FREE(cpu_ters);
    cudaFree(ters);
    cudaFree(Na);
    cudaFree(Na_sum);
    cudaFree(type);
    cudaFree(x);
    cudaFree(y);
    cudaFree(z);
    cudaFree(fx_ref);
    cudaFree(fy_ref);
    cudaFree(fz_ref);
    cudaFree(pe);
    cudaFree(sxx);
    cudaFree(syy);
    cudaFree(szz);
    cudaFree(fx);
    cudaFree(fy);
    cudaFree(fz);
    cudaFree(b);
    cudaFree(bp);
    cudaFree(f12x);
    cudaFree(f12y);
    cudaFree(f12z);
}


void Fitness::read_xyz_in(char* input_dir)
{
    print_line_1();
    printf("Started reading xyz.in.\n");
    print_line_2();
    char file_xyz[200];
    strcpy(file_xyz, input_dir);
    strcat(file_xyz, "/xyz.in");
    FILE *fid_xyz = my_fopen(file_xyz, "r");
    read_Nc(fid_xyz);
    read_Na(fid_xyz);
    read_xyz(fid_xyz);
    fclose(fid_xyz);
}


void Fitness::read_Nc(FILE* fid)
{
    int count = fscanf(fid, "%d", &Nc);
    if (count != 1) print_error("Reading error for xyz.in.\n");
    if (Nc < 1)
        print_error("Number of configurations should >= 1\n");
    else
        printf("Number of configurations = %d.\n", Nc);
}


void Fitness::read_Na(FILE* fid)
{
    int *cpu_Na;
    int *cpu_Na_sum; 
    MY_MALLOC(cpu_Na, int, Nc);
    MY_MALLOC(cpu_Na_sum, int, Nc);
    N = 0;
    for (int nc = 0; nc < Nc; ++nc) { cpu_Na_sum[nc] = 0; }
    for (int nc = 0; nc < Nc; ++nc)
    {
        int count = fscanf(fid, "%d", &cpu_Na[nc]);
        if (count != 1) print_error("Reading error for xyz.in.\n");
        N += cpu_Na[nc];
        if (cpu_Na[nc] < 1)
            print_error("Number of atoms %d should >= 1\n");
        else
            printf("N[%d] = %d.\n", nc, cpu_Na[nc]);
    }
    for (int nc = 1; nc < Nc; ++nc) 
        cpu_Na_sum[nc] = cpu_Na_sum[nc-1] + cpu_Na[nc-1];
    int mem = sizeof(int) * Nc;
    CHECK(cudaMalloc((void**)&Na, mem));
    CHECK(cudaMalloc((void**)&Na_sum, mem));
    CHECK(cudaMemcpy(Na, cpu_Na, mem, cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(Na_sum, cpu_Na_sum, mem, cudaMemcpyHostToDevice));
    MY_FREE(cpu_Na);
    MY_FREE(cpu_Na_sum);
} 


void Fitness::read_xyz(FILE* fid)
{
    int *cpu_type;
    double *cpu_x, *cpu_y, *cpu_z, *cpu_fx_ref, *cpu_fy_ref, *cpu_fz_ref;
    MY_MALLOC(cpu_type, int, N);
    MY_MALLOC(cpu_x, double, N);
    MY_MALLOC(cpu_y, double, N);
    MY_MALLOC(cpu_z, double, N);
    MY_MALLOC(cpu_fx_ref, double, N);
    MY_MALLOC(cpu_fy_ref, double, N);
    MY_MALLOC(cpu_fz_ref, double, N);
    num_types = 0;
    force_ref_square_sum = 0.0;
    for (int n = 0; n < N; n++)
    {
        int count = fscanf(fid, "%d%lf%lf%lf%lf%lf%lf", 
            &(cpu_type[n]), &(cpu_x[n]), &(cpu_y[n]), &(cpu_z[n]),
            &(cpu_fx_ref[n]), &(cpu_fy_ref[n]), &(cpu_fz_ref[n]));
        if (count != 7) { print_error("reading error for xyz.in.\n"); }
        if (cpu_type[n] > num_types) { num_types = cpu_type[n]; }
        force_ref_square_sum += cpu_fx_ref[n] * cpu_fx_ref[n]
                              + cpu_fy_ref[n] * cpu_fy_ref[n]
                              + cpu_fz_ref[n] * cpu_fz_ref[n];
    }
    num_types++;
    int m1 = sizeof(int) * N;
    int m2 = sizeof(double) * N;
    allocate_memory_gpu();
    CHECK(cudaMemcpy(type, cpu_type, m1, cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(x, cpu_x, m2, cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(y, cpu_y, m2, cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(z, cpu_z, m2, cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(fx_ref, cpu_fx_ref, m2, cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(fy_ref, cpu_fy_ref, m2, cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(fz_ref, cpu_fz_ref, m2, cudaMemcpyHostToDevice));
    MY_FREE(cpu_type);
    MY_FREE(cpu_x);
    MY_FREE(cpu_y);
    MY_FREE(cpu_z);
    MY_FREE(cpu_fx_ref);
    MY_FREE(cpu_fy_ref);
    MY_FREE(cpu_fz_ref);

    int n_entries = num_types * num_types * num_types;
    MY_MALLOC(cpu_ters, double, n_entries * NUM_PARAMS);
    CHECK(cudaMalloc((void**)&ters, sizeof(double) * n_entries * NUM_PARAMS));
}


void Fitness::allocate_memory_gpu(void)
{
    int m1 = sizeof(int) * N;
    int m2 = sizeof(double) * N;
    // read from CPU
    CHECK(cudaMalloc((void**)&type, m1));
    CHECK(cudaMalloc((void**)&x, m2));
    CHECK(cudaMalloc((void**)&y, m2));
    CHECK(cudaMalloc((void**)&z, m2));
    CHECK(cudaMalloc((void**)&fx_ref, m2));
    CHECK(cudaMalloc((void**)&fy_ref, m2));
    CHECK(cudaMalloc((void**)&fz_ref, m2));
    // Calculated on the GPU
    CHECK(cudaMalloc((void**)&pe, m2));
    CHECK(cudaMalloc((void**)&sxx, m2));
    CHECK(cudaMalloc((void**)&syy, m2));
    CHECK(cudaMalloc((void**)&szz, m2));
    CHECK(cudaMalloc((void**)&fx, m2));
    CHECK(cudaMalloc((void**)&fy, m2));
    CHECK(cudaMalloc((void**)&fz, m2));
    CHECK(cudaMalloc((void**)&b, m2 * MN));
    CHECK(cudaMalloc((void**)&bp, m2 * MN));
    CHECK(cudaMalloc((void**)&f12x, m2 * MN));
    CHECK(cudaMalloc((void**)&f12y, m2 * MN));
    CHECK(cudaMalloc((void**)&f12z, m2 * MN));
}


void Fitness::compute
(
    int population_size, int number_of_variables, 
    double *parameters_min, double *parameters_max,
    double* population, double* fitness
)
{
    double *parameters;
    double *error_gpu, *error_cpu;
    MY_MALLOC(error_cpu, double, 1);
    CHECK(cudaMalloc((void**)&error_gpu, sizeof(double) * 1));
    MY_MALLOC(parameters, double, number_of_variables);
    for (int n = 0; n < population_size; ++n)
    {
        double* individual = population + n * number_of_variables;
        for (int m = 0; m < number_of_variables; ++m)
        {
            double a = parameters_min[m];
            double b = parameters_max[m] - a;
            parameters[m] = a + b * individual[m];
        }
        update_potential(parameters);
        find_force();
        fitness[n] = get_fitness_force(error_cpu, error_gpu);
    }
    MY_FREE(parameters);
    MY_FREE(error_cpu);
    CHECK(cudaFree(error_gpu));
}


static __device__ void warp_reduce(volatile double* s, int t) 
{
    s[t] += s[t + 32]; s[t] += s[t + 16]; s[t] += s[t + 8];
    s[t] += s[t + 4];  s[t] += s[t + 2];  s[t] += s[t + 1];
}


static __global__ void gpu_sum_force_error
(
    int N, double *g_fx, double *g_fy, double *g_fz, 
    double *g_fx_ref, double *g_fy_ref, double *g_fz_ref, double *g_error
)
{
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int number_of_patches = (N - 1) / 1024 + 1; 
    __shared__ double s_error[1024];
    s_error[tid] = 0.0;
    for (int patch = 0; patch < number_of_patches; ++patch)
    {
        int n = tid + patch * 1024;
        if (n < N) 
        {
            double dx = g_fx[n] - g_fx_ref[n];
            double dy = g_fy[n] - g_fy_ref[n];
            double dz = g_fz[n] - g_fz_ref[n];
            s_error[tid] += dx * dx + dy * dy + dz * dz;
        }
    }
    __syncthreads();
    if (tid < 512) s_error[tid] += s_error[tid + 512]; __syncthreads();
    if (tid < 256) s_error[tid] += s_error[tid + 256]; __syncthreads();
    if (tid < 128) s_error[tid] += s_error[tid + 128]; __syncthreads();
    if (tid <  64) s_error[tid] += s_error[tid + 64];  __syncthreads();
    if (tid <  32) warp_reduce(s_error, tid);
    if (tid ==  0) { g_error[bid] = s_error[0]; }
}


double Fitness::get_fitness_force(double *error_cpu, double *error_gpu)
{
    gpu_sum_force_error<<<1, 1024>>>(N, fx, fy, fz, 
        fx_ref, fy_ref, fz_ref, error_gpu);
    CHECK(cudaMemcpy(error_cpu, error_gpu, sizeof(double), 
        cudaMemcpyDeviceToHost));
    error_cpu[0] /= force_ref_square_sum;
    return sqrt(error_cpu[0]);
}


static __global__ void gpu_sum_pe_error
(int *g_Na, int *g_Na_sum, double *g_pe, double *g_pe_ref, double *error_gpu)
{
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int Na = g_Na[bid];
    int offset = g_Na_sum[bid];
    __shared__ double s_pe[256];
    s_pe[tid] = 0.0;
    if (tid < Na)
    {
        int n = offset + tid; // particle index
        s_pe[tid] += g_pe[n];
    }
    __syncthreads();
    if (tid < 128) { s_pe[tid] += s_pe[tid + 128]; }  __syncthreads();
    if (tid <  64) { s_pe[tid] += s_pe[tid + 64];  }  __syncthreads();
    if (tid <  32) { warp_reduce(s_pe, tid);         }
    if (tid ==  0) 
    {
        double diff = s_pe[0] - g_pe_ref[bid];
        error_gpu[bid] = diff * diff;
    }
}


double Fitness::get_fitness_energy(double* error_cpu, double* error_gpu)
{ 
    gpu_sum_pe_error<<<Nc, 256>>>(Na, Na_sum, pe, pe_ref, error_gpu);
    int mem = sizeof(double) * Nc;
    CHECK(cudaMemcpy(error_cpu, error_gpu, mem, cudaMemcpyDeviceToHost));
    for (int n = 0; n < Nc; ++n)
    {
        error_cpu[0] += error_cpu[n];
    }
    return sqrt(error_cpu[0] / pe_ref_square_sum);
}


