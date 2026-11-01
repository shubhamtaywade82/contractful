# Gem Release Guide

Complete guide for automated gem releases with MFA security via GitHub Actions.

## Table of Contents

- [Quick Start](#quick-start)
- [One-Time Setup](#one-time-setup)
- [Release Process](#release-process)
- [Troubleshooting](#troubleshooting)
- [How It Works](#how-it-works)

---

## Quick Start

**Already configured?** Just bump version and push a tag:

```bash
# 1. Update version in lib/contractful/version.rb
# e.g., VERSION_INFO = [0, 1, 0]

# 2. Update history.md (promote Unreleased to dated release header)

# 3. Commit and tag
git add lib/contractful/version.rb history.md
git commit -m "Release 0.1.0: initial release"
git tag v0.1.0
git push origin master
git push origin v0.1.0

# 4. Done! GitHub Actions will automatically release to RubyGems
```

Check progress: https://github.com/shubhamtaywade82/contractful/actions

---

## One-Time Setup

### Prerequisites

- RubyGems account at https://rubygems.org
- MFA enabled on RubyGems account
- Admin access to GitHub repository

### Step 1: Get RubyGems API Key

1. Log in to https://rubygems.org
2. Go to **Edit Profile** → **API Keys** (or visit https://rubygems.org/profile/api_keys)
3. Click **New API Key**
4. Name: `GitHub Actions - contractful`
5. Scopes: Select **Push rubygems**
6. Click **Create**
7. **Copy the API key** (you won't see it again!)

### Step 2: Get RubyGems OTP Secret

This is needed because `rubygems_mfa_required = 'true'` in the gemspec requires OTP verification.

#### What You Need

The **OTP secret key** (not the 6-digit codes), which looks like:
```
JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP
```

Valid characters: `A-Z` and `2-7` only (Base32 encoding)

#### How to Get It

**Option A: If you saved it when enabling MFA**
- Check your password manager, notes, or screenshots

**Option B: Regenerate MFA (if you can't find it)**

1. Go to https://rubygems.org → **Edit Profile** → **Multi-factor Authentication**
2. Click **"Disable Multi-factor Authentication"**
3. Click **"Enable Multi-factor Authentication"** again
4. **IMPORTANT: Copy the secret key text** (e.g., `JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP`)
5. Scan the QR code with your authenticator app
6. Enter the 6-digit code to verify
7. **Update your authenticator app** (old codes won't work after regenerating)

#### Test Your Secret (Optional)

```bash
gem install rotp
ruby -r rotp -e "puts ROTP::TOTP.new('YOUR_SECRET_HERE').now"
```

This should output a 6-digit number matching your authenticator app.

### Step 3: Add Secrets to GitHub

1. Go to: https://github.com/shubhamtaywade82/contractful/settings/secrets/actions
2. Click **New repository secret**
3. Add **first secret**:
   - Name: `RUBYGEMS_API_KEY`
   - Value: Your API key from Step 1
   - Click **Add secret**
4. Add **second secret**:
   - Name: `RUBYGEMS_OTP_SECRET`
   - Value: Your OTP secret from Step 2
   - Click **Add secret**

### Step 4: Verify Setup

Your repository should now have two secrets:
- `RUBYGEMS_API_KEY`
- `RUBYGEMS_OTP_SECRET`

---

## Release Process

### Standard Release

```bash
# 1. Update version
vim lib/contractful/version.rb

# 2. Update history.md
vim history.md

# 3. Commit changes
git add lib/contractful/version.rb history.md
git commit -m "Release 0.1.0: initial contractful release"

# 4. Create and push tag
git tag v0.1.0
git push origin master
git push origin v0.1.0

# 5. Monitor release
# Visit: https://github.com/shubhamtaywade82/contractful/actions
```

### What Happens Automatically

When you push a tag (e.g., `v0.1.0`), the **Release** workflow (`.github/workflows/release.yml`) runs:

1. **Validate** tag version matches `lib/contractful/version.rb` (tag `v0.1.0` -> gem version `0.1.0`)
2. **Generate OTP code** from secret `RUBYGEMS_OTP_SECRET`
3. **Build gem** using `gem build contractful.gemspec`
4. **Push to RubyGems** with OTP using `GEM_HOST_API_KEY` (from secret `RUBYGEMS_API_KEY`)
5. **Attach gem to GitHub Release** - uploads `contractful-<version>.gem` as a downloadable asset on the GitHub Release for the tag

---

## Troubleshooting

### "Repushing of gem versions is not allowed"

**Problem:** You're trying to push a version that already exists on RubyGems.

**Solution:** Bump the version number in `lib/contractful/version.rb` to a new version.

### "Invalid OTP code"

**Problem:** The OTP secret in GitHub Secrets is incorrect.

**Solutions:**
1. Verify `RUBYGEMS_OTP_SECRET` matches your authenticator app's secret
2. Test locally: `ruby -r rotp -e "puts ROTP::TOTP.new('YOUR_SECRET').now"`
3. If still failing, regenerate MFA on RubyGems and update the secret

### "unauthorized" or "Access Denied"

**Problem:** API key is invalid or missing permissions.

**Solutions:**
1. Verify `RUBYGEMS_API_KEY` is set in GitHub Secrets
2. Check the API key has **"Push rubygems"** scope
3. Generate a new API key on RubyGems and update the secret

### "Tag version does not match gem version"

**Problem:** The git tag doesn't match the version in `lib/contractful/version.rb`.

**Solution:**
Ensure tag format is `vX.Y.Z` matching `Contractful::VERSION` (`X.Y.Z`).

---

## How It Works

### GitHub Actions Workflow

The workflow (`.github/workflows/release.yml`) runs when you push a tag:

```yaml
on:
  push:
    tags:
      - "v*"
```

### Security Features

- **MFA Required** - `rubygems_mfa_required = 'true'` in gemspec
- **Push Host Restricted** - `allowed_push_host = 'https://rubygems.org'` prevents accidental pushes
- **Encrypted Secrets** - API key and OTP secret stored securely in GitHub
- **Tag Validation** - Prevents accidental version mismatches
- **Audit Trail** - All releases logged in GitHub Actions
