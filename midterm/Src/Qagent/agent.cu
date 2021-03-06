﻿/*************************************************************************
/* ECE 285: GPU Programmming 2019 Winter quarter
/* Author and Instructer: Cheolhong An
/* Copyright 2019
/* University of California, San Diego
/*************************************************************************/
#include <cuda_runtime.h>
#include <cuda.h>
#include <stdio.h>
#include "agent.h"

// Improvement: adjust grid and block size
#define BLOCK_SIZE 128
#define NUM_ACTIONS 4
#define BOARD_SIZE 46
#define NUM_AGENT 512

// Helpers

// return the action with maximum Q value
__inline__ __device__ 
short findMaxQValAction(float* d_qtable, int x, int y) {
	short cand = RIGHT;
	int startIdx = y * (BOARD_SIZE * NUM_ACTIONS) + x * NUM_ACTIONS;
	#pragma unroll
	for (short i = RIGHT + 1; i <= TOP; ++i) {
		int candIdx = startIdx + cand;
		int curIdx = startIdx + i;
		float candQval = d_qtable[candIdx];
		float curQVal = d_qtable[curIdx];
		cand = curQVal > candQval ? i : cand;
	}
	return cand;
}
__global__ void setup_kernel(curandState *state) {
	int idx = threadIdx.x + blockDim.x*blockIdx.x;
	curand_init((unsigned long long)(clock() + idx), idx, 0, &state[idx]);
}

__global__ void actionInit(short *d_agentsActions) {
	int idx = threadIdx.x + blockDim.x * blockIdx.x;
	d_agentsActions[idx] = 0;
}

__global__ void qtableInit(float *d_qtable) {
	int iy = threadIdx.y + blockDim.y * blockIdx.y;
	int ix = threadIdx.x + blockDim.x * blockIdx.x;
	int idx = iy * BOARD_SIZE * NUM_ACTIONS + ix;
	d_qtable[idx] = 0;
}

__global__ void aliveInit(bool *d_isAlive) {
	int idx = threadIdx.x + blockDim.x * blockIdx.x;
	d_isAlive[idx] = true;
}

// Implementation:
__global__ void actionTaken(
	int2* cstate, 
	short *d_action, 
	float *d_qtable, 
	curandState *state, 
	float *ep) {
	float epsilon = *ep;
	int idx = threadIdx.x + blockDim.x * blockIdx.x;

	int x = cstate[idx].x;
	int y = cstate[idx].y;
	short cand = RIGHT;
	// gama greedy strategy:
	curandState localState = state[idx];
	float seed = curand_uniform(&localState);

	if (seed < epsilon) {
		cand = (short) (curand_uniform(&localState) * NUM_ACTIONS);
	} else {
		cand = findMaxQValAction(d_qtable, x, y);
	}
	d_action[idx] = cand;
	state[idx] = localState;
}

__global__ void qtableUpdate(
	int2* cstate, 
	int2* nstate, 
	float *rewards, 
	bool *d_isAlive,
	short *d_action, 
	float *d_qtable, 
	float gradientDec,
	float learningRate) {
	int idx = threadIdx.x + blockDim.x * blockIdx.x;
	short curAction = d_action[idx];
	int cx = cstate[idx].x;
	int cy = cstate[idx].y;

	int nx = nstate[idx].x;
	int ny = nstate[idx].y;

	// Improvement: use binar opreation to replace conditional clause
	if (d_isAlive[idx]) {
		// improvement: remove conditional clause
		float r = rewards[idx];
		d_isAlive[idx] = (r == 0);

		// Improvment: reduce memory access
		bool isAlive = (r == 0);

		// Find maximum next state expected value
		float max = 0;

		// if agent is alive in next state, set the future expected return
		if (isAlive) {
			short maxAction = findMaxQValAction(d_qtable, nx, ny);
			int maxIdx = ny * (BOARD_SIZE * NUM_ACTIONS) + nx * NUM_ACTIONS + maxAction;
			max = d_qtable[maxIdx];
		}

		// update formula
		int curIdx = cy * (BOARD_SIZE * NUM_ACTIONS) + cx * NUM_ACTIONS + curAction;
		float delta = gradientDec * (r + learningRate * max - d_qtable[curIdx]);
		d_qtable[curIdx] = d_qtable[curIdx] + delta;
	}
}

// Improvement: adjust epsilon decay rate, allow more learning time when epsilon is small
__global__ void updateEpsilon(float *epsilon) {
	float val = *epsilon;
	
	// Improvement: adjust epsilon in stages, allow more training time in low epsilon
	// reason: correct path will have enough time to propagate to further positions before hitting a mine
	if (val < 0.001) {
		(*epsilon) = 0;
	} else if (val < 0.01) {
		(*epsilon) = val - 0.001;
	} else if (val < 0.1) {
		(*epsilon) = val - 0.002f;
	} else {
		(*epsilon) = val - 0.005f;
	}
}

__global__ void epsilonInit(float *epsilon) {
	*epsilon = 1.0f;
}

// Implementations for host API
void Agent::init() {
	// update global variable
	int actualBlockSize = NUM_AGENT > BLOCK_SIZE ? BLOCK_SIZE : NUM_AGENT;
	block = dim3(actualBlockSize);
	grid = dim3((NUM_AGENT + block.x - 1) / block.x);
	
	this->numOfAgents = NUM_AGENT;
	this->initGlobalVariables();
	this->initAgents();
	this->initQTable();
}

void Agent::initAgents() {
	int actionMemSize = this->numOfAgents * sizeof(short);
	int aliveMemSize = this->numOfAgents * sizeof(bool);

	CHECK(cudaMalloc((void **)&d_action, actionMemSize));
	CHECK(cudaMalloc((void **)&d_isAlive, aliveMemSize));
	CHECK(cudaMalloc((void **)&randState, this->numOfAgents * sizeof(curandState)));

	actionInit <<<grid, block>>> (d_action);
	aliveInit <<<grid, block >>> (d_isAlive);
	setup_kernel <<<grid, block >>>(randState);
}

void Agent::initQTable() {
	// init qtable, agent action states
	int qtableX = BOARD_SIZE * NUM_ACTIONS;
	int qtableY = BOARD_SIZE;
	int qtableMemSize = qtableX * qtableY * sizeof(float);
	CHECK(cudaMalloc((void **)&d_qtable, qtableMemSize));
	
	int qy = 2;
	dim3 qBlock(NUM_AGENT / qy, qy);
	dim3 qGrid((qtableX + qBlock.x - 1) / qBlock.x, (qtableY + qBlock.y - 1) / qBlock.y);
	qtableInit <<<qGrid, qBlock >>> (d_qtable);
}

void Agent::initGlobalVariables() {
	float ep = 1.0;
	CHECK(cudaMalloc((void **)&epsilon, sizeof(float)));
	epsilonInit <<<1, 1 >>> (epsilon);

	this->learningRate = 0.32f;
	this->gradientDec = 0.55f;
}

float Agent::decEpsilon() {
	updateEpsilon <<<1, 1 >>>(this->epsilon);
	float h_epsilon = 0.0f;
	CHECK(cudaMemcpy(&h_epsilon, epsilon, sizeof(float), cudaMemcpyDeviceToHost));
	return h_epsilon;
}

void Agent::takeAction(int2* cstate) {
	actionTaken <<<grid, block >>> (cstate, d_action, d_qtable, randState, this->epsilon);
}

void Agent::updateAgents(int2* cstate, int2* nstate, float *rewards) {
	qtableUpdate <<<grid, block >>> (cstate, nstate, rewards, d_isAlive, d_action, d_qtable, gradientDec, learningRate);
}