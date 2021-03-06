/*
 * Copyright (c) 2002-2004 Apple Computer, Inc. All Rights Reserved.
 * 
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

#include "SecTrust.h"
#include "SecTrustPriv.h"
#include "Trust.h"
#include <security_keychain/SecTrustSettingsPriv.h>
#include "SecBridge.h"
#include "SecTrustSettings.h"
#include "SecCertificatePriv.h"
#include <security_utilities/cfutilities.h>
#include <CoreFoundation/CoreFoundation.h>

//
// CF boilerplate
//
CFTypeID SecTrustGetTypeID(void)
{
	BEGIN_SECAPI

	return gTypes().Trust.typeID;

	END_SECAPI1(_kCFRuntimeNotATypeID)
}


//
// Sec* API bridge functions
//
OSStatus SecTrustCreateWithCertificates(
	CFArrayRef certificates,
	CFTypeRef policies,
	SecTrustRef *trustRef)
{
    BEGIN_SECAPI
	Required(trustRef);
    *trustRef = (new Trust(certificates, policies))->handle();
    END_SECAPI
}


OSStatus
SecTrustSetPolicies(SecTrustRef trustRef, CFTypeRef policies)
{
	BEGIN_SECAPI
	Trust::required(trustRef)->policies(policies);
	END_SECAPI
}


OSStatus SecTrustSetParameters(
    SecTrustRef trustRef,
    CSSM_TP_ACTION action,
    CFDataRef actionData)
{
    BEGIN_SECAPI
    Trust *trust = Trust::required(trustRef);
    trust->action(action);
    trust->actionData(actionData);
    END_SECAPI
}


OSStatus SecTrustSetAnchorCertificates(SecTrustRef trust, CFArrayRef anchorCertificates)
{
    BEGIN_SECAPI
    Trust::required(trust)->anchors(anchorCertificates);
    END_SECAPI
}

OSStatus SecTrustSetAnchorCertificatesOnly(SecTrustRef trust, Boolean anchorCertificatesOnly)
{
    BEGIN_SECAPI
	//FIXME: requires implementation
    return errSecUnimplemented;
    END_SECAPI
}

OSStatus SecTrustSetKeychains(SecTrustRef trust, CFTypeRef keychainOrArray)
{
    BEGIN_SECAPI
	StorageManager::KeychainList keychains;
	globals().storageManager.optionalSearchList(keychainOrArray, keychains);
    Trust::required(trust)->searchLibs() = keychains;
    END_SECAPI
}


OSStatus SecTrustSetVerifyDate(SecTrustRef trust, CFDateRef verifyDate)
{
    BEGIN_SECAPI
    Trust::required(trust)->time(verifyDate);
    END_SECAPI
}


CFAbsoluteTime SecTrustGetVerifyTime(SecTrustRef trust)
{
	CFAbsoluteTime verifyTime = 0;
    OSStatus __secapiresult;
	try {
		CFRef<CFDateRef> verifyDate = Trust::required(trust)->time();
		verifyTime = CFDateGetAbsoluteTime(verifyDate);
		
		__secapiresult=noErr;
	}
	catch (const MacOSError &err) { __secapiresult=err.osStatus(); }
	catch (const CommonError &err) { __secapiresult=SecKeychainErrFromOSStatus(err.osStatus()); }
	catch (const std::bad_alloc &) { __secapiresult=memFullErr; }
	catch (...) { __secapiresult=internalComponentErr; }
    return verifyTime;
}

OSStatus SecTrustEvaluate(SecTrustRef trustRef, SecTrustResultType *resultP)
{
    BEGIN_SECAPI
    Trust *trust = Trust::required(trustRef);
    trust->evaluate();
    if (resultP) {
        *resultP = trust->result();
        secdebug("SecTrustEvaluate", "SecTrustEvaluate trust result = %d", (int)*resultP);
    }
    END_SECAPI
}


//
// Construct the "official" result evidence and return it
//
OSStatus SecTrustGetResult(
    SecTrustRef trustRef,
    SecTrustResultType *result,
	CFArrayRef *certChain, CSSM_TP_APPLE_EVIDENCE_INFO **statusChain)
{
    BEGIN_SECAPI
    Trust *trust = Trust::required(trustRef);
    if (result)
        *result = trust->result();
    if (certChain && statusChain)
        trust->buildEvidence(*certChain, TPEvidenceInfo::overlayVar(*statusChain));
    END_SECAPI
}


//
// Retrieve extended validation trust results
//
OSStatus SecTrustCopyExtendedResult(SecTrustRef trust, CFDictionaryRef *result)
{
    BEGIN_SECAPI
	Trust *trustObj = Trust::required(trust);
	if (result == nil)
		return paramErr;
	trustObj->extendedResult(*result);
    END_SECAPI
}

//
// Retrieve CSSM-level information for those who want to dig down
//
OSStatus SecTrustGetCssmResult(SecTrustRef trust, CSSM_TP_VERIFY_CONTEXT_RESULT_PTR *result)
{
    BEGIN_SECAPI
    Required(result) = Trust::required(trust)->cssmResult();
    END_SECAPI
}

//
// Retrieve CSSM_LEVEL TP return code
//
OSStatus SecTrustGetCssmResultCode(SecTrustRef trustRef, OSStatus *result)
{
    BEGIN_SECAPI
	Trust *trust = Trust::required(trustRef);
	if (trust->result() == kSecTrustResultInvalid)
		return paramErr; 
	else
		Required(result) = trust->cssmResultCode();
    END_SECAPI
}

OSStatus SecTrustGetTPHandle(SecTrustRef trust, CSSM_TP_HANDLE *handle)
{
    BEGIN_SECAPI
    Required(handle) = Trust::required(trust)->getTPHandle();
    END_SECAPI
}

OSStatus SecTrustCopyPolicies(SecTrustRef trust, CFArrayRef *policies)
{
    BEGIN_SECAPI
    CFArrayRef currentPolicies = Trust::required(trust)->policies();
	if (currentPolicies != NULL)
	{
		CFRetain(currentPolicies);
	}
	
    Required(policies) =  currentPolicies;
    END_SECAPI
}

OSStatus SecTrustCopyCustomAnchorCertificates(SecTrustRef trust, CFArrayRef *anchorCertificates)
{
    BEGIN_SECAPI
    CFRef<CFArrayRef> customAnchors(Trust::required(trust)->anchors());
    Required(anchorCertificates) = (customAnchors) ?
        (const CFArrayRef)CFRetain(customAnchors) : (const CFArrayRef)NULL;
    END_SECAPI
}

//
// Get the user's default anchor certificate set
//
OSStatus SecTrustCopyAnchorCertificates(CFArrayRef *anchorCertificates)
{
    BEGIN_SECAPI

	return SecTrustSettingsCopyUnrestrictedRoots(
		true, true, true,		/* all domains */
		anchorCertificates);

    END_SECAPI
}

/* new in 10.6 */
SecKeyRef SecTrustCopyPublicKey(SecTrustRef trust)
{
	SecKeyRef pubKey = NULL;
	CFArrayRef certChain = NULL;
    OSStatus __secapiresult;
	try {
		Trust *trustObj = Trust::required(trust);
		CSSM_TP_APPLE_EVIDENCE_INFO *statusChain = NULL;
		// buildEvidence will throw an error if trust is not yet evaluated
		trustObj->buildEvidence(certChain, TPEvidenceInfo::overlayVar(statusChain));
		__secapiresult = noErr;
	}
	catch (const MacOSError &err) { __secapiresult=err.osStatus(); }
	catch (const CommonError &err) { __secapiresult=SecKeychainErrFromOSStatus(err.osStatus()); }
	catch (const std::bad_alloc &) { __secapiresult=memFullErr; }
	catch (...) { __secapiresult=internalComponentErr; }
	
	if (certChain) {
		if (CFArrayGetCount(certChain) > 0) {
			SecCertificateRef cert = (SecCertificateRef) CFArrayGetValueAtIndex(certChain, 0);
			__secapiresult = SecCertificateCopyPublicKey(cert, &pubKey);
		}
		CFRelease(certChain);
	}
    return pubKey;
}

/* new in 10.6 */
CFIndex SecTrustGetCertificateCount(SecTrustRef trust)
{
	CFIndex chainLen = 0;
    OSStatus __secapiresult;
	try {
		//FIXME: implementation required
		// - trust reference is required
		// - check that trust reference has been evaluated first
		// - return number of certificates in chain
		
		__secapiresult=noErr;
	}
	catch (const MacOSError &err) { __secapiresult=err.osStatus(); }
	catch (const CommonError &err) { __secapiresult=SecKeychainErrFromOSStatus(err.osStatus()); }
	catch (const std::bad_alloc &) { __secapiresult=memFullErr; }
	catch (...) { __secapiresult=internalComponentErr; }
    return chainLen;
}

/* new in 10.6 */
SecCertificateRef SecTrustGetCertificateAtIndex(SecTrustRef trust, CFIndex ix)
{
	SecCertificateRef certificate = NULL;
    OSStatus __secapiresult;
	try {
		//FIXME: implementation required
		// - trust reference is required
		// - check that trust reference has been evaluated first
		// - return certificate at index
		
		__secapiresult=noErr;
	}
	catch (const MacOSError &err) { __secapiresult=err.osStatus(); }
	catch (const CommonError &err) { __secapiresult=SecKeychainErrFromOSStatus(err.osStatus()); }
	catch (const std::bad_alloc &) { __secapiresult=memFullErr; }
	catch (...) { __secapiresult=internalComponentErr; }
    return certificate;
}




/* deprecated in 10.5 */
OSStatus SecTrustGetCSSMAnchorCertificates(const CSSM_DATA **cssmAnchors,
	uint32 *cssmAnchorCount)
{
	BEGIN_SECAPI
	CertGroup certs;
	Trust::gStore().getCssmRootCertificates(certs);
	Required(cssmAnchors) = certs.blobCerts();
	Required(cssmAnchorCount) = certs.count();
	END_SECAPI
}


//
// Get and set user trust settings. Deprecated in 10.5. 
// User Trust getter, deprecated, works as it always has. 
//
OSStatus SecTrustGetUserTrust(SecCertificateRef certificate,
    SecPolicyRef policy, SecTrustUserSetting *trustSetting)
{
	BEGIN_SECAPI
	StorageManager::KeychainList searchList;
	globals().storageManager.getSearchList(searchList);
	Required(trustSetting) = Trust::gStore().find(
		Certificate::required(certificate),
		Policy::required(policy),
		searchList);
	END_SECAPI
}

//
// The public setter, also deprecated; it maps to the appropriate 
// Trust Settings call if possible, else throws unimpErr. 
//
OSStatus SecTrustSetUserTrust(SecCertificateRef certificate,
    SecPolicyRef policy, SecTrustUserSetting trustSetting)
{
	SecTrustSettingsResult tsResult = kSecTrustSettingsResultInvalid;
	OSStatus ortn;
	Boolean isRoot;

	Policy::required(policy);
	switch(trustSetting) {
		case kSecTrustResultProceed:
			/* different SecTrustSettingsResult depending in root-ness */
			ortn = SecCertificateIsSelfSigned(certificate, &isRoot);
			if(ortn) {
				return ortn;
			}
			if(isRoot) {
				tsResult = kSecTrustSettingsResultTrustRoot;
			}
			else {
				tsResult = kSecTrustSettingsResultTrustAsRoot;
			}
			break;
		case kSecTrustResultDeny:
			tsResult = kSecTrustSettingsResultDeny;
			break;
		default:
			return unimpErr;
	}

	/* make a usage constraints dictionary */
	CFRef<CFMutableDictionaryRef> usageDict(CFDictionaryCreateMutable(NULL,
		0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
	CFDictionaryAddValue(usageDict, kSecTrustSettingsPolicy, policy);
	if(tsResult != kSecTrustSettingsResultTrustRoot) {
		/* skip if we're specifying the default */
		SInt32 result = tsResult;
		CFNumberRef cfNum = CFNumberCreate(NULL, kCFNumberSInt32Type, &result);
		CFDictionarySetValue(usageDict, kSecTrustSettingsResult, cfNum);
		CFRelease(cfNum);
	}
	return SecTrustSettingsSetTrustSettings(certificate, kSecTrustSettingsDomainUser, 
		usageDict);
}

//
// This one is the now-private version of what SecTrustSetUserTrust() used to 
// be. The public API can no longer manipulate User Trust settings, only 
// view them. 
//
OSStatus SecTrustSetUserTrustLegacy(SecCertificateRef certificate,
    SecPolicyRef policy, SecTrustUserSetting trustSetting)
{
	BEGIN_SECAPI
	switch (trustSetting) {
    case kSecTrustResultProceed:
    case kSecTrustResultConfirm:
    case kSecTrustResultDeny:
    case kSecTrustResultUnspecified:
		break;
	default:
		MacOSError::throwMe(errSecInvalidTrustSetting);
	}
	Trust::gStore().assign(
		Certificate::required(certificate),
		Policy::required(policy),
		trustSetting);
	END_SECAPI
}

/*   SecGetAppleTPHandle - @@@NOT EXPORTED YET; copied from SecurityInterface, 
                           but could be useful in the future.
*/
/* 
CSSM_TP_HANDLE
SecGetAppleTPHandle()
{
	BEGIN_SECAPI
	return TP(gGuidAppleX509TP)->handle();
	END_SECAPI1(NULL);
}
*/


