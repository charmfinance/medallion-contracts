# Medallion

This repository contains proof-of-concept contracts for Medallion.


## Overview

Medallion is protocol designed to improve returns for liquidity providers. It achieves this using *strategies*, contracts that calculate and update swap fees on-the-fly.

The protocol is implemented as a Uniswap V4 hook. Any Uniswap V4 pool using this hook will therefore include all the functionality and benefits of the Medallion protocol.

Anyone can create a strategy and bid for the right to attach it to a pool in a continuous auction, in a manner similar to the am-AMM. The highest bidder becomes the *strategist* for that pool and pays rent to LPs each block and in return receives all swap fees while they remain the highest bidder. They are therefore incentivized to design strategist that maximise fee revenue, while a competitive auction ensures most of that revenue goes to LPs as rent.


## Repository structure

The main contract is `NeptuneHook`, a Uniswap V4 hook that auctions off the right to set and receive all swap fees. Unit tests for this contract can be found in `test/MedallionHook.t.sol`.

Strategies can be created by anyone and can contain any functionality as long as they implement the `IStrategy` interface. Example strategies can be found in `src/strategies`.

