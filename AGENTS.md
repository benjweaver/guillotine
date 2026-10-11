# Guillotine distribution

- Use the standard Homebrew cask and release-to-tap update flow used by Revoke.
- Casks download ordinary GitHub release URLs. Do not add private download
  strategies, credential handling, or token requirements for installation.
- Ben will make the app and tap repositories public for release. Do not change
  repository visibility on his behalf.
- The local release script updates the tap directly after publishing; never add
  scheduled workflows that poll for releases.
