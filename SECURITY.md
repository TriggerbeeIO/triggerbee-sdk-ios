# Security Policy

## Reporting a Vulnerability

If you believe you've found a security issue in the Triggerbee iOS SDK, please
**do not** open a public GitHub issue. Instead, email **support@triggerbee.com**
with:

- A description of the issue and the impact you observed
- Steps to reproduce (proof-of-concept code is welcome)
- The SDK version, host iOS version, and any relevant configuration
- Your name / handle if you'd like credit in the release notes

We aim to acknowledge reports within **2 business days** and ship a fix or
mitigation within **30 days** for confirmed issues, depending on severity.

## Supported Versions

While we're pre-1.0, only the **latest minor release** receives security fixes.
Once 1.0 ships, this policy will extend to the previous major version for 12
months after a new major is released.

| Version  | Supported |
|----------|-----------|
| 0.1.x    | ✓         |
| < 0.1.0  | ✗         |

## Scope

In scope:

- Code in this repository (`Sources/Triggerbee/`)
- Distributed Swift Package artifacts
- Documentation that could mislead consumers into insecure usage

Out of scope (report to the relevant project instead):

- Vulnerabilities in upstream Foundation / URLSession / WebKit — report to Apple via
  the Feedback Assistant.
- The Triggerbee backend / dashboard — email **support@triggerbee.com** for those
  as well, but note the SDK repo is not the right tracker.
