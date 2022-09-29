# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a
Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2022-09-27

### Changed

- The creation of an orderbook is a witness protected function. The downstream
  contract has the liberty of deciding when and how a new instance of an
  orderbook should be created.

### Added

- Draft implementation for fees. At the moment, only the permission concept is
  figured out and data model. To collect fees, the downstream collection
  contract calls witness protected `collect_fees` function.
- Logic for optionally witness protecting trading entry functions.

## [0.2.0] - 2022-09-21

### Added

- Endpoint to buy a specific listed NFT.
- Getter for OB collection id.
- Getters for ask and bid fields.

### Changed

- Using `nft-protocol` v0.2.0 and Sui v0.9.0
