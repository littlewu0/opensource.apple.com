/*
 * Copyright (c) 2000-2003 Apple Computer, Inc. All rights reserved.
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

/*
 * Modification History
 *
 * June 1, 2001			Allan Nathanson <ajn@apple.com>
 * - public API conversion
 *
 * March 24, 2000		Allan Nathanson <ajn@apple.com>
 * - initial revision
 */


#include "configd.h"
#include "session.h"
#include "pattern.h"


__private_extern__
int
__SCDynamicStoreSetValue(SCDynamicStoreRef store, CFStringRef key, CFDataRef value, Boolean internal)
{
	SCDynamicStorePrivateRef	storePrivate = (SCDynamicStorePrivateRef)store;
	int				sc_status	= kSCStatusOK;
	CFDictionaryRef			dict;
	CFMutableDictionaryRef		newDict;
	Boolean				newEntry	= FALSE;
	CFStringRef			sessionKey;
	CFStringRef			storeSessionKey;

	if (!store || (storePrivate->server == MACH_PORT_NULL)) {
		return kSCStatusNoStoreSession;	/* you must have an open session to play */
	}

	if (_configd_trace) {
		SCTrace(TRUE, _configd_trace,
			CFSTR("%s%s : %5d : %@\n"),
			internal ? "*set " : "set  ",
			storePrivate->useSessionKeys ? "t " : "  ",
			storePrivate->server,
			key);
	}

	/*
	 * 1. Ensure that we hold the lock.
	 */
	sc_status = __SCDynamicStoreLock(store, TRUE);
	if (sc_status != kSCStatusOK) {
		return sc_status;
	}

	/*
	 * 2. Grab the current (or establish a new) dictionary for this key.
	 */

	dict = CFDictionaryGetValue(storeData, key);
	if (dict) {
		newDict = CFDictionaryCreateMutableCopy(NULL,
							0,
							dict);
	} else {
		newDict = CFDictionaryCreateMutable(NULL,
						    0,
						    &kCFTypeDictionaryKeyCallBacks,
						    &kCFTypeDictionaryValueCallBacks);
	}

	/*
	 * 3. Update the dictionary entry to be saved to the store.
	 */
	newEntry = !CFDictionaryContainsKey(newDict, kSCDData);
	CFDictionarySetValue(newDict, kSCDData, value);

	sessionKey = CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), storePrivate->server);

	/*
	 * 4. Manage per-session keys.
	 */
	if (storePrivate->useSessionKeys) {
		if (newEntry) {
			CFArrayRef		keys;
			CFMutableDictionaryRef	newSession;
			CFMutableArrayRef	newKeys;
			CFDictionaryRef		session;

			/*
			 * Add this key to my list of per-session keys
			 */
			session = CFDictionaryGetValue(sessionData, sessionKey);
			keys = CFDictionaryGetValue(session, kSCDSessionKeys);
			if ((keys == NULL) ||
			    (CFArrayGetFirstIndexOfValue(keys,
							 CFRangeMake(0, CFArrayGetCount(keys)),
							 key) == kCFNotFound)) {
				/*
				 * if no session keys defined "or" keys defined but not
				 * this one...
				 */
				if (keys != NULL) {
					/* this is the first session key */
					newKeys = CFArrayCreateMutableCopy(NULL, 0, keys);
				} else {
					/* this is an additional session key */
					newKeys = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
				}
				CFArrayAppendValue(newKeys, key);

				/* update session dictionary */
				newSession = CFDictionaryCreateMutableCopy(NULL, 0, session);
				CFDictionarySetValue(newSession, kSCDSessionKeys, newKeys);
				CFRelease(newKeys);
				CFDictionarySetValue(sessionData, sessionKey, newSession);
				CFRelease(newSession);
			}

			/*
			 * Mark the key as a "session" key and track the creator.
			 */
			CFDictionarySetValue(newDict, kSCDSession, sessionKey);
		} else {
			/*
			 * Since we are using per-session keys and this key already
			 * exists, check if it was created by "our" session
			 */
			dict = CFDictionaryGetValue(storeData, key);
			if (!CFDictionaryGetValueIfPresent(dict, kSCDSession, (void *)&storeSessionKey) ||
			    !CFEqual(sessionKey, storeSessionKey)) {
				/*
				 * if the key exists and is not a session key or
				 * if the key exists it's not "our" session.
				 */
				sc_status = kSCStatusKeyExists;
				CFRelease(sessionKey);
				CFRelease(newDict);
				goto done;
			}
		}
	} else {
		/*
		* Since we are updating this key we need to check and, if
		* necessary, remove the indication that this key is on
		* another session's remove-on-close list.
		*/
		if (!newEntry &&
		    CFDictionaryGetValueIfPresent(newDict, kSCDSession, (void *)&storeSessionKey) &&
		    !CFEqual(sessionKey, storeSessionKey)) {
			CFStringRef	removedKey;

			/* We are no longer a session key! */
			CFDictionaryRemoveValue(newDict, kSCDSession);

			/* add this session key to the (session) removal list */
			removedKey = CFStringCreateWithFormat(NULL, 0, CFSTR("%@:%@"), storeSessionKey, key);
			CFSetAddValue(removedSessionKeys, removedKey);
			CFRelease(removedKey);
		}
	}

	CFRelease(sessionKey);

	/*
	 * 5. Update the dictionary entry in the store.
	 */

	CFDictionarySetValue(storeData, key, newDict);
	CFRelease(newDict);

	/*
	 * 6. For "new" entries to the store, check the deferred cleanup
	 *    list. If the key is flagged for removal, remove it from the
	 *    list since any defined regex's for this key are still defined
	 *    and valid. If the key is not flagged then iterate over the
	 *    sessionData dictionary looking for regex keys which match the
	 *    updated key. If a match is found then we mark those keys as
	 *    being watched.
	 */

	if (newEntry) {
		if (CFSetContainsValue(deferredRemovals, key)) {
			CFSetRemoveValue(deferredRemovals, key);
		} else {
			patternAddKey(key);
		}
	}

	/*
	 * 7. Mark this key as "changed". Any "watchers" will be notified
	 *    as soon as the lock is released.
	 */
	CFSetAddValue(changedKeys, key);

    done :

	/*
	 * 8. Release our lock.
	 */
	__SCDynamicStoreUnlock(store, TRUE);

	return sc_status;
}

__private_extern__
kern_return_t
_configset(mach_port_t			server,
	   xmlData_t			keyRef,		/* raw XML bytes */
	   mach_msg_type_number_t	keyLen,
	   xmlData_t			dataRef,	/* raw XML bytes */
	   mach_msg_type_number_t	dataLen,
	   int				oldInstance,
	   int				*newInstance,
	   int				*sc_status
)
{
	CFDataRef		data		= NULL;	/* data (un-serialized) */
	CFStringRef		key		= NULL;	/* key  (un-serialized) */
	serverSessionRef	mySession	= getSession(server);

	/* un-serialize the key */
	if (!_SCUnserializeString(&key, NULL, (void *)keyRef, keyLen)) {
		*sc_status = kSCStatusFailed;
		goto done;
	}

	if (!isA_CFString(key)) {
		*sc_status = kSCStatusInvalidArgument;
		goto done;
	}

	/* un-serialize the data */
	if (!_SCUnserializeData(&data, (void *)dataRef, dataLen)) {
		*sc_status = kSCStatusFailed;
		goto done;
	}

	if (!mySession) {
		*sc_status = kSCStatusNoStoreSession;	/* you must have an open session to play */
		goto done;
	}

	*sc_status = __SCDynamicStoreSetValue(mySession->store, key, data, FALSE);
	*newInstance = 0;

    done :

	if (key)	CFRelease(key);
	if (data)	CFRelease(data);
	return KERN_SUCCESS;
}

static void
setSpecificKey(const void *key, const void *value, void *context)
{
	CFStringRef		k	= (CFStringRef)key;
	CFDataRef		v	= (CFDataRef)value;
	SCDynamicStoreRef	store	= (SCDynamicStoreRef)context;

	if (!isA_CFString(k)) {
		return;
	}

	if (!isA_CFData(v)) {
		return;
	}

	(void) __SCDynamicStoreSetValue(store, k, v, TRUE);

	return;
}

static void
removeSpecificKey(const void *value, void *context)
{
	CFStringRef		k	= (CFStringRef)value;
	SCDynamicStoreRef	store	= (SCDynamicStoreRef)context;

	if (!isA_CFString(k)) {
		return;
	}

	(void) __SCDynamicStoreRemoveValue(store, k, TRUE);

	return;
}

static void
notifySpecificKey(const void *value, void *context)
{
	CFStringRef		k	= (CFStringRef)value;
	SCDynamicStoreRef	store	= (SCDynamicStoreRef)context;

	if (!isA_CFString(k)) {
		return;
	}

	(void) __SCDynamicStoreNotifyValue(store, k, TRUE);

	return;
}

__private_extern__
int
__SCDynamicStoreSetMultiple(SCDynamicStoreRef store, CFDictionaryRef keysToSet, CFArrayRef keysToRemove, CFArrayRef keysToNotify)
{
	SCDynamicStorePrivateRef	storePrivate	= (SCDynamicStorePrivateRef)store;
	int				sc_status	= kSCStatusOK;

	if (!store || (storePrivate->server == MACH_PORT_NULL)) {
		return kSCStatusNoStoreSession;	/* you must have an open session to play */
	}

	if (_configd_trace) {
		SCTrace(TRUE, _configd_trace,
			CFSTR("set m   : %5d : %d set, %d remove, %d notify\n"),
			storePrivate->server,
			keysToSet    ? CFDictionaryGetCount(keysToSet)    : 0,
			keysToRemove ? CFArrayGetCount     (keysToRemove) : 0,
			keysToNotify ? CFArrayGetCount     (keysToNotify) : 0);
	}

	/*
	 * Ensure that we hold the lock
	 */
	sc_status = __SCDynamicStoreLock(store, TRUE);
	if (sc_status != kSCStatusOK) {
		return sc_status;
	}

	/*
	 * Set the new/updated keys
	 */
	if (keysToSet) {
		CFDictionaryApplyFunction(keysToSet,
					  setSpecificKey,
					  (void *)store);
	}

	/*
	 * Remove the specified keys
	 */
	if (keysToRemove) {
		CFArrayApplyFunction(keysToRemove,
				     CFRangeMake(0, CFArrayGetCount(keysToRemove)),
				     removeSpecificKey,
				     (void *)store);
	}

	/*
	 * Notify the specified keys
	 */
	if (keysToNotify) {
		CFArrayApplyFunction(keysToNotify,
				     CFRangeMake(0, CFArrayGetCount(keysToNotify)),
				     notifySpecificKey,
				     (void *)store);
	}

	/* Release our lock */
	__SCDynamicStoreUnlock(store, TRUE);

	return sc_status;
}

__private_extern__
kern_return_t
_configset_m(mach_port_t		server,
	     xmlData_t			dictRef,
	     mach_msg_type_number_t	dictLen,
	     xmlData_t			removeRef,
	     mach_msg_type_number_t	removeLen,
	     xmlData_t			notifyRef,
	     mach_msg_type_number_t	notifyLen,
	     int			*sc_status)
{
	CFDictionaryRef		dict		= NULL;		/* key/value dictionary (un-serialized) */
	serverSessionRef	mySession	= getSession(server);
	CFArrayRef		notify		= NULL;		/* keys to notify (un-serialized) */
	CFArrayRef		remove		= NULL;		/* keys to remove (un-serialized) */

	if (dictRef && (dictLen > 0)) {
		/* un-serialize the key/value pairs to set */
		if (!_SCUnserialize((CFPropertyListRef *)&dict, NULL, (void *)dictRef, dictLen)) {
			*sc_status = kSCStatusFailed;
			goto done;
		}

		if (!isA_CFDictionary(dict)) {
			*sc_status = kSCStatusInvalidArgument;
			goto done;
		}
	}

	if (removeRef && (removeLen > 0)) {
		/* un-serialize the keys to remove */
		if (!_SCUnserialize((CFPropertyListRef *)&remove, NULL, (void *)removeRef, removeLen)) {
			*sc_status = kSCStatusFailed;
			goto done;
		}

		if (!isA_CFArray(remove)) {
			*sc_status = kSCStatusInvalidArgument;
			goto done;
		}
	}

	if (notifyRef && (notifyLen > 0)) {
		/* un-serialize the keys to notify */
		if (!_SCUnserialize((CFPropertyListRef *)&notify, NULL, (void *)notifyRef, notifyLen)) {
			*sc_status = kSCStatusFailed;
			goto done;
		}

		if (!isA_CFArray(notify)) {
			*sc_status = kSCStatusInvalidArgument;
			goto done;
		}
	}

	if (!mySession) {
		/* you must have an open session to play */
		*sc_status = kSCStatusNoStoreSession;
		goto done;
	}

	*sc_status = __SCDynamicStoreSetMultiple(mySession->store, dict, remove, notify);

    done :

	if (dict)	CFRelease(dict);
	if (remove)	CFRelease(remove);
	if (notify)	CFRelease(notify);

	return KERN_SUCCESS;
}
