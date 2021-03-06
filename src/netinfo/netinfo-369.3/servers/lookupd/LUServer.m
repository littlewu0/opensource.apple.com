/*
 * Copyright (c) 1999 Apple Computer, Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * "Portions Copyright (c) 1999 Apple Computer, Inc.  All Rights
 * Reserved.  This file contains Original Code and/or Modifications of
 * Original Code as defined in and that are subject to the Apple Public
 * Source License Version 1.0 (the 'License').  You may not use this file
 * except in compliance with the License.  Please obtain a copy of the
 * License at http://www.apple.com/publicsource and read it before using
 * this file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT.  Please see the
 * License for the specific language governing rights and limitations
 * under the License."
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

/*
 * LUServer.m
 *
 * Lookup server for lookupd
 *
 * Copyright (c) 1995, NeXT Computer Inc.
 * All rights reserved.
 * Written by Marc Majka
 */

#import <NetInfo/system_log.h>
#import <NetInfo/syslock.h>
#import "LUServer.h"
#import "LUCachedDictionary.h"
#import "LUPrivate.h"
#import "Controller.h"
#import "Config.h"
#import "Dyna.h"
#import "DNSAgent.h"
#import <NetInfo/dsutil.h>
#import <netinfo/ni.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <sys/types.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <ctype.h>

#define MaxNetgroupRecursion 5
#define XDRSIZE 8192

#define MICROSECONDS 1000000

#define SOCK_UNSPEC 0
#define IPPROTO_UNSPEC 0

#define WAIT_FOR_PARALLEL_REPLY 100
#define forever for(;;)

#define GAI_SEARCHING 0
#define GAI_GOT_DATA 1
#define GAI_NO_DATA 2

static unsigned int
milliseconds_since(struct timeval t)
{
	struct timeval now, delta;
	unsigned int millisec;

	gettimeofday(&now, NULL);

	delta.tv_sec = now.tv_sec - t.tv_sec;

	if (t.tv_usec > now.tv_usec)
	{
		now.tv_usec += MICROSECONDS;
		delta.tv_sec -= 1;
	}

	delta.tv_usec = now.tv_usec - t.tv_usec;

	millisec = ((delta.tv_sec * MICROSECONDS) + delta.tv_usec) / 1000;
	return millisec;
}

static int
is_a_number(char *s)
{
	int i, len;

	if (s == NULL) return 0;

	len = strlen(s);
	for (i = 0; i < len; i++)
	{
		if (isdigit(s[i]) == 0) return 0;
	}

	return 1;
}

@implementation LUServer

+ (LUServer *)alloc
{
	id s;

	s = [super alloc];
	system_log(LOG_DEBUG, "Allocated LUServer 0x%08x", (int)s);
	return s;
}

- (char **)lookupOrderForCategory:(LUCategory)cat
{
	LUDictionary *cdict;
	char **order;

	cdict = [configManager configForCategory:cat fromConfig:configurationArray];
	if (cdict != nil)
	{
		order = [cdict valuesForKey:"LookupOrder"];
		if (order != NULL) return order;
	}

	cdict = [configManager configGlobal:configurationArray];
	if (cdict == nil) return NULL;

	order = [cdict valuesForKey:"LookupOrder"];
	return order;
}

- (LUServer *)init
{
	[super init];

	agentList = [[LUArray alloc] init];
	[agentList setBanner:"LUServer agent list"];

	idle = YES;
	state = ServerStateIdle;
	currentAgent = nil;
	currentCall = NULL;

	return self;
}

- (BOOL)isIdle
{
	return idle;
}

/*
 * Called on check out / check in.
 */
- (void)setIsIdle:(BOOL)yn
{
	Thread *t;

	t = [Thread currentThread];

	if (yn)
	{
		if (t != myThread)
		{
			system_log(LOG_ERR, "Thread %s attempted to idle server %x owned by thread %s", [t name], (unsigned int)self, [myThread name]);
			return;
		}

		idle = YES;
		state = ServerStateIdle;
		myThread = nil;
	}
	else
	{
		if (myThread != nil)
		{
			system_log(LOG_ERR, "Thread %s attempted to use server %x owned by thread %s", [t name], (unsigned int)self, [myThread name]);
			return;
		}

		idle = NO;
		state = ServerStateActive;
		myThread = t;
	}
}

- (LUAgent *)agentNamed:(char *)name
{
	id agentClass;
	char *arg, *cname, *cserv;
	int i, len;
	id agent;

	if (name == NULL) return nil;

	arg = strchr(name, ':');
	if (arg != NULL) arg += 1;

	cname = [LUAgent canonicalAgentName:name];
	if (cname == NULL) return nil;

	cserv = [LUAgent canonicalServiceName:name];
	if (cserv == NULL)
	{
		free(cname);
		return nil;
	}

	len = [agentList count];
	for (i = 0; i < len; i++)
	{
		agent = [agentList objectAtIndex:i];
		if (streq([agent serviceName], cserv))
		{
			free(cname);
			free(cserv);
			return agent;
		}
	}

	agent = nil;
	agentClass = [controller agentClassNamed:cname];
	free(cname);
	free(cserv);
	if (agentClass == nil)
	{
		agent = [[Dyna alloc] initWithArg:name];
	}
	else
	{
		agent = [[agentClass alloc] initWithArg:arg];
	}

	if (agent == nil) return nil;

	[agentList addObject:agent];
	[agent release];

	system_log(LOG_DEBUG, "LUServer 0x%08x added agent 0x%08x (%s)", (int)self, (int)agent, [agent serviceName]);

	return agent;
}

- (void)dealloc
{
	int i, len;
	LUAgent *agent;

	if (agentList != nil)
	{
		len = [agentList count];
		for (i = len - 1; i >= 0; i--)
		{
			agent = [agentList objectAtIndex:i];
			system_log(LOG_DEBUG, "%d: server 0x%08x released agent 0x%08x (%s)", i, (int)self, (int)agent, [agent serviceName]);
			[agentList removeObject:agent];
		}

		[agentList release];
	}

	system_log(LOG_DEBUG, "Deallocated LUServer 0x%08x", (int)self);

	[super dealloc];
}

- (void)addTime:(unsigned int)t hit:(BOOL)found forKey:(const char *)key
{
	unsigned long calls, time, hits;
	char *str, *v;

	if (key == NULL) return;

	calls = 0;
	time = 0;
	hits = 0;

	syslock_lock(statsLock);

	v = [statistics valueForKey:(char *)key];
	if (v != NULL) sscanf(v, "%lu %lu %lu", &calls, &hits, &time);

	calls += 1;
	if (found) hits += 1;
	time += t;

	str = NULL;
	asprintf(&str, "%lu %lu %lu", calls, hits, time);
	if (str != NULL)
	{
		[statistics setValue:str forKey:(char *)key];
		free(str);
	}

	syslock_unlock(statsLock);
}

- (void)recordCall:(char *)method args:(char *)args time:(unsigned int)t hit:(BOOL)found
{
	/* total of all calls */
	[self addTime:t hit:found forKey:"total"];

	/* total calls of this lookup method */
	if (method == NULL) return;

	[self addTime:t hit:found forKey:method];

	if (trace_enabled) system_log(LOG_DEBUG, "Call: %s %s   time: %u status: %s", method, (args == NULL) ? "" : args, t, found ? "OK" : "Failed");
}

- (void)recordSearch:(char *)method args:(char *)args infoSystem:(const char *)info time:(unsigned int)t hit:(BOOL)found
{
	char *key;

	if (info == NULL) return;

	/* total for this info system */
	[self addTime:t hit:found forKey:info];

	/* total for this method in this info system */
	if (method == NULL) return;

	key = NULL;
	asprintf(&key, "%s %s", info, method);
	if (key != NULL)
	{
		[self addTime:t hit:found forKey:key];
		free(key);
	}

	if (trace_enabled) system_log(LOG_DEBUG, "Search %s: %s %s   time: %u status: %s", info, method, (args == NULL) ? "" : args, t, found ? "OK" : "Failed");
}

- (LUDictionary *)stamp:(LUDictionary *)item
	key:(char *)key
	agent:(LUAgent *)agent
 	category:(LUCategory)cat
{
	BOOL cacheEnabled;
	char *scratch;
	const char *sname;

	if (item == nil) return nil;

	cacheEnabled = [cacheAgent cacheIsEnabledForCategory:cat];
	[item setCategory:cat];

	sname = [agent shortName];
	if (sname == NULL) return item;


	if (strcmp(sname, "Cache"))
	{
		scratch = NULL;

		if (cat == LUCategoryBootp)
		{
			asprintf(&scratch, "%s: %s %s (%s / %s)", sname, [LUAgent categoryName:cat], [item valueForKey:"name"], [item valueForKey:"en_address"], [item valueForKey:"ip_address"]);
		}
		else
		{
			asprintf(&scratch, "%s: %s %s", sname, [LUAgent categoryName:cat], [item valueForKey:"name"]);
		}

		if (scratch != NULL)
		{
			[item setBanner:scratch];
			free(scratch);
		}
	}

	if (cacheEnabled && (strcmp(sname, "Cache")))
	{
		[cacheAgent addObject:item key:key category:cat];
	}

	if ([item isNegative])
	{
		[item release];
		return nil;
	}

	return item;
}

- (unsigned long)state
{
	return state;
}

- (LUAgent *)currentAgent
{
	return currentAgent;
}

- (char *)currentCall
{
	return currentCall;
}

static char *
appendDomainName(char *h, char *d)
{
	char *q;

	if (h == NULL) return NULL;
	if (d == NULL) return copyString(h);

	q = NULL;
	asprintf(&q, "%s.%s", h, d);
	return q;
}

/*
 * Given a host name, returns a list of possible variations
 * based on our DNS domain name / DNS domain search list.
 */
- (char **)hostNameList:(char *)host
{
	char **l, **dns;
	char *p, *s;
	int i, len;

	if (host == NULL) return NULL;

	/* Bail out if we are shutting down (prevents a call to controller) */
	if (shutting_down) return NULL;

	l = NULL;
	l = appendString(host, l);

	dns = [controller dnsSearchList];

	/* If no DNS, list is just (host) */
	if (dns == NULL) return l;

	len = listLength(dns);

	p = strchr(host, '.');
	if (p == NULL)
	{
		/*
		 * Unqualified host name.
		 * Return (host, host.<dns[0]>, host.<dns[1]>, ...)
		 */		 
		for (i = 0; i < len; i++)
		{
			s = appendDomainName(host, dns[i]);
			if (s == NULL) continue;
			l = appendString(s, l);
			free(s);
		}
		return l;
	}

	/*
	 * Hostname is qualified.
	 * If domain is in dns search list, we return (host.domain, host).
	 * Otherwise, return (host.domain).
	 */
	for (i = 0; i < len; i++)
	{
		if (streq(p+1, dns[i]))
		{
			/* Strip domain name, append host to list */
			*p = '\0';
			l = appendString(host, l);
			*p = '.';
			return l;
		}
	}

	return l;
}

- (LUArray *)allItemsWithCategory:(LUCategory)cat
{
	char **lookupOrder;
	const char *sname;
	LUArray *all;
	LUArray *sub;
	LUAgent *agent;
	LUDictionary *stamp;
	LUDictionary *item;
	int i, len;
	int j, sublen;
	BOOL cacheEnabled;
	char *scratch, *caller;
	struct timeval allStart;
	struct timeval sysStart;
	unsigned int sysTime;
	unsigned int allTime;

	if (cat >= NCATEGORIES) return nil;

	caller = NULL;

	if (statistics_enabled)
	{
		gettimeofday(&allStart, (struct timezone *)NULL);
		asprintf(&caller, "all %s", [LUAgent categoryName:cat]);
		currentCall = caller;
	}

	cacheEnabled = [cacheAgent cacheIsEnabledForCategory:cat];
	if (cacheEnabled)
	{
		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);
			currentAgent = cacheAgent;
			state = ServerStateQuerying;
		}

		all = [cacheAgent allItemsWithCategory:cat];

		if (statistics_enabled)
		{
			state = ServerStateActive;
			currentAgent = nil;
			sysTime = milliseconds_since(sysStart);
			[self recordSearch:caller args:NULL infoSystem:"Cache" time:sysTime hit:(all != nil)];
		}

		if (all != nil)
		{
			if (statistics_enabled)
			{
				allTime = milliseconds_since(allStart);
				[self recordCall:caller args:NULL time:allTime hit:YES];
				currentCall = NULL;
			}

			if (caller != NULL) free(caller);
			return all;
		}
	}

	all = [[LUArray alloc] init];

	lookupOrder = [self lookupOrderForCategory:cat];
	len = listLength(lookupOrder);
	agent = nil;
	for (i = 0; i < len; i++)
	{
		agent = [self agentNamed:lookupOrder[i]];
		if (agent == nil) continue;
		sname = [agent shortName];
		if ((sname != NULL) && (streq(sname, "Cache"))) continue;

		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);

			currentAgent = agent;
			state = ServerStateQuerying;
		}

		sub = [agent allItemsWithCategory:cat];

		if (statistics_enabled)
		{
			state = ServerStateActive;
			currentAgent = nil;

			sysTime = milliseconds_since(sysStart);

			[self recordSearch:caller args: NULL infoSystem:sname time:sysTime hit:(sub != nil)];
		}

		if (sub != nil)
		{
			/* Merge validation info from this agent into "all" array */
			sublen = [sub validationStampCount];
			for (j = 0; j < sublen; j++)
			{
				stamp = [sub validationStampAtIndex:j];
				if ([stamp isNegative]) continue;

				[stamp setCategory:cat];
				[all addValidationStamp:stamp];
			}

			sublen = [sub count];
			for (j = 0; j < sublen; j++)
			{
				item = [sub objectAtIndex:j];
				[item setCategory:cat];
				[all addObject:item];
			}

			[sub release];
		}
	}

	if (statistics_enabled)
	{
		allTime = milliseconds_since(allStart);
		[self recordCall:caller args:NULL time:allTime hit:([all count] != 0)];
		currentCall = NULL;
	}

	if (caller != NULL) free(caller);

	if ([all count] == 0)
	{
		[all release];
		return nil;
	}

	scratch = NULL;
	asprintf(&scratch, "LUServer: all %s", [LUAgent categoryName:cat]);
	if (scratch != NULL)
	{
		[all setBanner:scratch];
		free(scratch);
	}

	if (cacheEnabled) [cacheAgent addArray:all];
	return all;
}

- (LUArray *)query:(LUDictionary *)pattern
{
	char **lookupOrder;
	char *catname;
	char *pdesc;
	const char *sname;
	LUArray *all, *list;
	LUArray *sub;
	LUAgent *agent;
	LUDictionary *item;
	LUCategory cat;
	int i, len;
	int j, sublen;
	BOOL isnumber;
	char *pagent;
	struct timeval listStart;
	struct timeval sysStart;
	unsigned int sysTime;
	unsigned int listTime;
	unsigned int where;
	int single_item;

	if (pattern == nil) return nil;

	where = [pattern indexForKey:"_lookup_category"];
	if (where == IndexNull) return nil;

	catname = [pattern valueAtIndex:where];
	if (catname == NULL) return nil;

	/* Backward compatibility for clients that do direct "query" calls */
	cat = -1;
	isnumber = YES;
	len = strlen(catname);
	for (i = 0; (i < len) && isnumber; i++)
	{
		if ((catname[i] < '0') || (catname[i] > '9')) isnumber = NO;
	}

	if (isnumber) cat = atoi(catname);
	else cat = [LUAgent categoryWithName:catname];

	if (cat > NCATEGORIES) return nil;

	pdesc = NULL;
	if (statistics_enabled)
	{
		pdesc = [pattern description];
		gettimeofday(&listStart, (struct timezone *)NULL);
		currentCall = "query";
	}

	pagent = NULL;
	where = [pattern indexForKey:"_lookup_agent"];
	if (where != IndexNull) pagent = [pattern valueAtIndex:where];

	single_item = 0;
	where = [pattern indexForKey:"_lookup_single"];
	if (where != IndexNull) single_item = 1;

	if ((pagent != NULL) && (!strcmp(pagent, "Cache")))
	{
		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);
			currentAgent = cacheAgent;
			state = ServerStateQuerying;
		}

		list = nil;

		all = [cacheAgent allItemsWithCategory:cat];
		if (all != nil)
		{
			list = [all filter:pattern];
			[all release];
		}

		if (statistics_enabled)
		{
			state = ServerStateActive;
			currentAgent = nil;
			sysTime = milliseconds_since(sysStart);
			[self recordSearch:currentCall args:pdesc  infoSystem:"Cache" time:sysTime hit:(list != nil)];

			listTime = milliseconds_since(listStart);
			[self recordCall:currentCall args:pdesc time:listTime hit:(list != nil)];
			currentCall = NULL;
		}

		if (pdesc != NULL) free(pdesc);

		return list;
	}

	all = [[LUArray alloc] init];

	lookupOrder = [self lookupOrderForCategory:cat];
	len = listLength(lookupOrder);
	agent = nil;
	for (i = 0; i < len; i++)
	{
		agent = [self agentNamed:lookupOrder[i]];
		if (agent == nil) continue;
		sname = [agent shortName];
		if ((sname != NULL) && (streq(sname, "Cache"))) continue;
		if ((pagent != NULL) && strcmp(sname, pagent)) continue;

		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);

			currentAgent = agent;
			state = ServerStateQuerying;
		}

		sub = [agent query:pattern category:cat];

		if (statistics_enabled)
		{
			state = ServerStateActive;
			currentAgent = nil;
			sysTime = milliseconds_since(sysStart);
			[self recordSearch:currentCall args:pdesc infoSystem:sname time:sysTime hit:(sub != nil)];
		}

		if (sub != nil)
		{
			sublen = [sub count];
			for (j = 0; j < sublen; j++)
			{
				item = [sub objectAtIndex:j];
				[item setCategory:cat];
				[all addObject:item];
			}

			[sub release];
		}

		if ((single_item == 1) && ([all count] != 0)) break;
	}

	if (statistics_enabled)
	{
		listTime = milliseconds_since(listStart);
		[self recordCall:currentCall args:pdesc time:listTime hit:([all count] != 0)];
		currentCall = NULL;
	}

	if (pdesc != NULL) free(pdesc);

	if ([all count] == 0)
	{
		[all release];
		return nil;
	}

	return all;
}

- (LUDictionary *)allGroupsWithUser:(char *)name
{
	char **lookupOrder;
	LUDictionary *all;
	LUDictionary *sub;
	LUAgent *agent;
	int i, len;
	BOOL cacheEnabled;
	char *scratch;
	struct timeval allStart;
	struct timeval sysStart;
	unsigned int sysTime;
	unsigned int allTime;

	if (statistics_enabled)
	{
		gettimeofday(&allStart, (struct timezone *)NULL);
		currentCall = "initgroups";
	}

	if (name == NULL)
	{
		if (statistics_enabled)
		{
			[self recordSearch:currentCall args:name infoSystem:"Failed" time:0 hit:YES];
			[self recordCall:currentCall args:name time:0 hit:NO];
			currentCall = NULL;
		}
		return nil;
	}

	cacheEnabled = [cacheAgent cacheIsEnabledForCategory:LUCategoryInitgroups];
	if (cacheEnabled)
	{
		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);
			currentAgent = cacheAgent;
			state = ServerStateQuerying;
		}

		all = [cacheAgent allGroupsWithUser:name];

		if (statistics_enabled)
		{
			state = ServerStateActive;
			currentAgent = nil;
			sysTime = milliseconds_since(sysStart);
			[self recordSearch:currentCall args:name infoSystem:"Cache" time:sysTime hit:(all != nil)];
		}

		if (all != nil)
		{
			if (statistics_enabled)
			{
				allTime = milliseconds_since(allStart);
				[self recordCall:currentCall args:name time:allTime hit:YES];
				currentCall = NULL;
			}
			return all;
		}
	}

	all = [[LUDictionary alloc] initTimeStamped];
	[all setValue:name forKey:"name"];

	lookupOrder = [self lookupOrderForCategory:LUCategoryInitgroups];
	len = listLength(lookupOrder);
	agent = nil;
	for (i = 0; i < len; i++)
	{
		agent = [self agentNamed:lookupOrder[i]];
		if (agent == nil) continue;
		if (streq([agent shortName], "Cache")) continue;

		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);
			currentAgent = agent;
			state = ServerStateQuerying;
		}

		sub = [agent allGroupsWithUser:name];

		if (statistics_enabled)
		{
			state = ServerStateActive;
				currentAgent = nil;
			sysTime = milliseconds_since(sysStart);
			[self recordSearch:currentCall args:name infoSystem:[agent shortName] time:sysTime hit:(sub != nil)];
		}

		if (sub != nil)
		{
			[all mergeKey:"gid" from:sub];
			[sub release];
		}
	}

	if (statistics_enabled)
	{
		allTime = milliseconds_since(allStart);
		[self recordCall:currentCall args:name time:allTime hit:([all count] != 0)];
		currentCall = NULL;
	}

	scratch = NULL;
	asprintf(&scratch, "LUServer: all groups with user %s", name);
	if (scratch != NULL)
	{
		[all setBanner:scratch];
		free(scratch);
	}

	if (cacheEnabled) [cacheAgent setInitgroups:all forUser:name];
	return [self stamp:all key:"name" agent:self category:LUCategoryInitgroups];
}

/*
 * Called by netgroupWithName:
 * Does not search the Cache.
 */
- (LUDictionary *)allNetgroupsWithName:(char *)name namelist:(char ***)listp depth:(int)depth alerted:(int *)alert;
{
	LUDictionary *group, *subgroup;
	char **lookupOrder, **list, **subnames, **tmp;
	LUDictionary *item;
	LUAgent *agent;
	int i, j, len;
	char *scratch;
	struct timeval allStart;
	struct timeval sysStart;
	unsigned int sysTime;
	unsigned int allTime;
	BOOL allFound, found;

	if (name == NULL) return nil;
	if (listp == NULL) return nil;
	list = *listp;

	/* Stop infinite recursion */
	if (list != NULL)
	{
		for (i = 0; list[i] != NULL; i++)
		{
			if (streq(list[i], name))
			{
				if (*alert == 0)
				{
					for (j = i; list[j + 1] != NULL; j++);
					if (j == 0)
					{
						system_log(LOG_WARNING, "netgroup %s contains itself as a member", name);
					}
					else
					{
						system_log(LOG_WARNING, "netgroup %s: recursive cycle at depth %d - netgroup %s includes netgroup %s", list[0], depth, list[j], name);
					}
					*alert = 1;
				}
				return nil;
			}
		}
	}

	list = appendString(name, list);
	*listp = list;

	if (statistics_enabled)
	{
		gettimeofday(&allStart, (struct timezone *)NULL);
		currentCall = "netgroup name";
	}

	lookupOrder = [self lookupOrderForCategory:LUCategoryNetgroup];
	len = listLength(lookupOrder);
	if (len == 0)
	{
		currentCall = NULL;
		return nil;
	}

	group = [[LUDictionary alloc] initTimeStamped];
	[group setValue:name forKey:"name"];

	scratch = NULL;
	asprintf(&scratch, "LUServer: netgroup %s", name);
	if (scratch != NULL)
	{
		[group setBanner:scratch];
		free(scratch);
	}

	allFound = NO;

	for (i = 0; i < len; i++)
	{
		agent = [self agentNamed:lookupOrder[i]];
		if (agent == nil) continue;
		if (streq([agent shortName], "Cache")) continue;

		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);
			currentAgent = agent;
			state = ServerStateQuerying;
		}

		found = NO;
		item = [agent netgroupWithName:name];
		if (item != nil)
		{
			found = YES;
			allFound = YES;
			[group mergeKey:"hosts" from:item];
			[group mergeKey:"users" from:item];
			[group mergeKey:"domains" from:item];
			[group mergeKey:"netgroups" from:item];
			[item release];
		}

		if (statistics_enabled)
		{
			state = ServerStateActive;
			currentAgent = nil;
			sysTime = milliseconds_since(sysStart);
			[self recordSearch:currentCall args:name infoSystem:[agent shortName] time:sysTime hit:found];
		}
	}

	if (statistics_enabled)
	{
		allTime = milliseconds_since(allStart);
		[self recordCall:currentCall args:name time:allTime hit:allFound];
		currentCall = NULL;
	}

	if (!allFound)
	{
		[group release];
		return nil;
	}

	/* For each group in netgroups list, look up the group and merge in */
	tmp = [group valuesForKey:"netgroups"];
	if (tmp == NULL) return group;

	/* Copy the list - [group mergeKey:"netgroups" from:subgroup] below will clobber it */
	subnames = NULL;
	for (i = 0; tmp[i] != NULL; i++) subnames = appendString(tmp[i], subnames);

	for (i = 0; subnames[i] != NULL; i++)
	{
		subgroup = [self allNetgroupsWithName:subnames[i] namelist:listp depth:(depth+1) alerted:alert];
		if (subgroup != nil)
		{
			[group mergeKey:"hosts" from:subgroup];
			[group mergeKey:"users" from:subgroup];
			[group mergeKey:"domains" from:subgroup];
			[group mergeKey:"netgroups" from:subgroup];
			[subgroup release];
		}
	}

	freeList(subnames);

	return group;
}

- (LUDictionary *)groupWithKey:(char *)key value:(char *)val
{
	LUArray *all;
	char **lookupOrder;
	LUDictionary *item;
	LUAgent *agent;
	int i, len;
	char *scratch, *str;
	struct timeval allStart;
	struct timeval sysStart;
	unsigned int sysTime;
	unsigned int allTime;
	BOOL cacheEnabled;
	LUDictionary *q;

	if (key == NULL) return nil;
	if (val == NULL) return nil;

	str = NULL;

	scratch = NULL;
	asprintf(&scratch, "%s %s", key, val);

	if (statistics_enabled)
	{
		gettimeofday(&allStart, (struct timezone *)NULL);
		asprintf(&str, "%s %s", [LUAgent categoryName:LUCategoryGroup], key);
		currentCall = str;
	}

	lookupOrder = [self lookupOrderForCategory:LUCategoryGroup];
	item = nil;
	len = listLength(lookupOrder);

	if (len == 0)
	{
		if (scratch != NULL) free(scratch);
		if (str != NULL) free(str);
		return nil;
	}

	cacheEnabled = [cacheAgent cacheIsEnabledForCategory:LUCategoryGroup];
	if (cacheEnabled)
	{
		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);
			currentAgent = cacheAgent;
			state = ServerStateQuerying;
		}

		item = [cacheAgent itemWithKey:key value:val category:LUCategoryGroup];

		if (statistics_enabled)
		{
			state = ServerStateActive;
			currentAgent = nil;
			sysTime = milliseconds_since(sysStart);
			[self recordSearch:currentCall args:scratch infoSystem:"Cache" time:sysTime hit:(item != nil)];
		}

		if (item != nil)
		{
			if (statistics_enabled)
			{
				allTime = milliseconds_since(allStart);
				[self recordCall:currentCall args:scratch time:allTime hit:YES];
				currentCall = NULL;
			}
			if (str != NULL) free(str);
			if (scratch != NULL) free(scratch);

			if ([item isNegative])
			{
				[item release];
				return nil;
			}

			return item;
		}
	}

	if (str != NULL) free(str);
	if (scratch != NULL) free(scratch);

	if (statistics_enabled) currentCall = NULL;

	q = [[LUDictionary alloc] init];
	[q setValue:val forKey:key];

	scratch = NULL;
	asprintf(&scratch, "%u", LUCategoryGroup);
	if (scratch != NULL)
	{
		[q setValue:scratch forKey:"_lookup_category"];
		free(scratch);
	}

	all = [self query:q];
	[q release];

	if (all == nil)
	{
		agent = [self agentNamed:lookupOrder[len - 1]];
		if (agent == nil) return nil;

		if (streq([agent shortName], "NIL"))
		{
			item = [agent itemWithKey:key value:val category:LUCategoryGroup];
			return [self stamp:item key:key agent:agent category:LUCategoryGroup];
		}

		return nil;
	}

	item = [[LUDictionary alloc] initTimeStamped];
	[item setCategory:LUCategoryGroup];

	scratch = NULL;
	asprintf(&scratch, "LUServer: group %s %s", key, val);
	if (scratch != NULL)
	{
		[item setBanner:scratch];
		free(scratch);
	}

	len = [all count];
	for (i = 0; i < len; i++)
	{
		[item mergeKey:"name" from:[all objectAtIndex:i]];
		[item mergeKey:"gid" from:[all objectAtIndex:i]];
		[item mergeKey:"users" from:[all objectAtIndex:i]];
	}

	[all release];

	if (cacheEnabled) [cacheAgent addObject:item key:key category:LUCategoryGroup];

	return item;
}

- (LUDictionary *)netgroupWithName:(char *)name
{
	LUDictionary *item;
	BOOL cacheEnabled;
	struct timeval sysStart;
	unsigned int sysTime = 0;
	char **namelist;
	int alert;

	if (name == NULL) return nil;

	cacheEnabled = [cacheAgent cacheIsEnabledForCategory:LUCategoryNetgroup];
	if (cacheEnabled)
	{
		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);
			currentAgent = cacheAgent;
			state = ServerStateQuerying;
		}

		item = [cacheAgent itemWithKey:"name" value:name category:LUCategoryNetgroup];

		if (statistics_enabled)
		{
			state = ServerStateActive;
			currentAgent = nil;
			sysTime = milliseconds_since(sysStart);
			[self recordSearch:currentCall args:name infoSystem:"Cache" time:sysTime hit:(item != nil)];
		}

		if (item != nil)
		{
			if (statistics_enabled)
			{
				[self recordCall:currentCall args:name time:sysTime hit:YES];
				currentCall = NULL;
			}

			return item;
		}
	}

	if (statistics_enabled) currentCall = NULL;

	namelist = NULL;
	alert = 0;
	item = [self allNetgroupsWithName:name namelist:&namelist depth:0 alerted:&alert];
	freeList(namelist);

	if (item == nil) return nil;

	if (cacheEnabled) [cacheAgent addObject:item key:name category:LUCategoryNetgroup];
	return item;
}

/* 
 * This is the search routine for itemWithKey:value:category
 */
- (LUDictionary *)findItemWithKey:(char *)key
	value:(char *)val
	category:(LUCategory)cat
{
	char **lookupOrder;
	const char *sname;
	LUDictionary *item;
	LUAgent *agent;
	int i, j, len, nether;
	char **etherAddrs;
	struct timeval allStart;
	struct timeval sysStart;
	unsigned int sysTime;
	unsigned int allTime;
	char *str, **myaddrs;
	BOOL tryRealName, isEtherAddr, isHostByIP;
	struct in_addr a4;
	struct in6_addr a6;
	char paddr[64];

	str = NULL;
	asprintf(&str, "%s %s", [LUAgent categoryName:cat], key);
	currentCall = str;

	lookupOrder = [self lookupOrderForCategory:cat];
	item = nil;
	len = listLength(lookupOrder);
	tryRealName = NO;
	if ((cat == LUCategoryUser) && (streq(key, "name"))) tryRealName = YES;

	isHostByIP = NO;

	isEtherAddr = NO;
	if (streq(key, "en_address")) isEtherAddr = YES;

	/*
	 * Convert addresses to canonical form.
	 * if inet_aton, inet_pton, or inet_ntop can't deal with them
	 * we leave the address alone - user may have some private idea
	 * of addresses.
	 */
	if (cat == LUCategoryHost)
	{
		if (streq(key, "ip_address"))
		{
			isHostByIP = YES;
			if (inet_aton(val, &a4) == 1)
			{
				if (inet_ntop(AF_INET, &a4, paddr, 64) != NULL) val = paddr;
			}
		}
		else if (streq(key, "ipv6_address"))
		{
			isHostByIP = YES;
			if (inet_pton(AF_INET6, val, &a6) == 1)
			{
				if (inet_ntop(AF_INET6, &a6, paddr, 64) != NULL) val = paddr;
			}
		}
	}

	if (statistics_enabled) gettimeofday(&allStart, (struct timezone *)NULL);

	for (i = 0; i < len; i++)
	{
		agent = [self agentNamed:lookupOrder[i]];
		if (agent == nil) continue;

		if (statistics_enabled) 
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);

			currentAgent = agent;
			state = ServerStateQuerying;
		}

		if (isEtherAddr)
		{
			/* Try all possible variations on leading zeros in the address */
			etherAddrs = [LUAgent variationsOfEthernetAddress:val];
			nether = listLength(etherAddrs);
			for (j = 0; j < nether; j++)
			{
				item = [agent itemWithKey:key value:etherAddrs[j] category:cat];
				if (item != nil) break;
			}

			freeList(etherAddrs);
		}
		else
		{
			item = [agent itemWithKey:key value:val category:cat];
			/*
			 * N.B. we omit NI from this search since it handles the
			 * name / realname case itself.  
			 */
			if (tryRealName && (item == nil) && strcmp([agent shortName], "NI"))
			{
				item = [agent itemWithKey:"realname" value:val category:cat];
			}
		}

		if (statistics_enabled) 
		{
			state = ServerStateActive;
			currentAgent = nil;

			sysTime = milliseconds_since(sysStart);
			sname = [agent shortName];
			[self recordSearch:currentCall args:val infoSystem:sname time:sysTime hit:(item != nil)];
		}

		if (item != nil)
		{
			if (statistics_enabled)
			{
				allTime = milliseconds_since(allStart);
				[self recordCall:currentCall args:val time:allTime hit:YES];
				currentCall = NULL;
			}

			if (str != NULL) free(str);
			return [self stamp:item key:key agent:agent category:cat];
		}
	}

	/*
	 * Check if this is a IP address for a local interface.
	 * We re-use the isHostByIP flag.
	 */
	if (isHostByIP)
	{
		isHostByIP = NO;

		myaddrs = [controller netAddrList];
		if (myaddrs != NULL)
		{
			for (i = 0; myaddrs[i] != NULL; i++)
			{
				if (streq(myaddrs[i], val))
				{
					isHostByIP = YES;
					break;
				}
			}
		}
	}

	/*
	 * If we failed to find a name for a local interface
	 * We return a negative record.
	 */
	if (isHostByIP)
	{
		agent = [self agentNamed:"NIL"];

		item = [[LUDictionary alloc] initTimeStamped];
		[item setNegative:YES];
		[item setValue:val forKey:key];
		[item setValue:"NIL" forKey:"_lookup_agent"];
		[item setValue:"NIL" forKey:"_lookup_info_system"];
		[item setValue:"-1" forKey:"_lookup_NIL_best_before"];

		if (statistics_enabled)
		{
			allTime = milliseconds_since(allStart);
			[self recordSearch:currentCall args:val infoSystem:"NIL" time:allTime hit:YES];
			[self recordCall:currentCall args:val time:allTime hit:NO];

			currentCall = NULL;
		}

		if (str != NULL) free(str);
		return [self stamp:item key:key agent:agent category:cat];
	}

	if (statistics_enabled)
	{
		allTime = milliseconds_since(allStart);
		[self recordSearch:currentCall args:val infoSystem:"Failed" time:allTime hit:YES];
		[self recordCall:currentCall args:val time:allTime hit:NO];

		currentCall = NULL;
	}

	if (str != NULL) free(str);

	return nil;
}

- (void)preferBootpAddress:(char *)addr
	key:(char *)key
	target:(char *)tkey
	dict:(LUDictionary *)dict
{
	char **kVals, **tVals;
	char *t;
	int i, target, kLen, tLen, tLast;

	kVals = [dict valuesForKey:key];
	tVals = [dict valuesForKey:tkey];

	tLen = listLength(tVals);
	if (tLen == 0) return;

	kLen = listLength(kVals);
	if (kLen == 0) return;

	tLast = tLen - 1;
	target = 0;

	for (i = 0; i < kLen; i++)
	{
		if (i == tLast) break;

		if (streq(addr, kVals[i]))
		{
			target = i;
			break;
		}
	}

	[dict removeKey:key];
	[dict setValue:addr forKey:key];

	t = copyString(tVals[target]);
	[dict removeKey:tkey];
	[dict setValue:t forKey:tkey];
	freeString(t);
}

/*
 * Find an item.  This method handles some special cases.
 * It calls findItemWithKey:value:category to do the work.
 */
- (LUDictionary *)itemWithKey:(char *)key
	value:(char *)val
	category:(LUCategory)cat
{
	LUDictionary *item;
	int freeVal;

	freeVal = 0;

	if ((key == NULL) || (val == NULL) || (cat > NCATEGORIES))
	{
		return nil;
	}

	if (cat == LUCategoryGroup)
	{
		return [self groupWithKey:key value:val];
	}

	if (cat == LUCategoryNetgroup)
	{
		return [self netgroupWithName:val];
	}

	if (cat == LUCategoryHost)
	{
		val = lowerCase(val);
		freeVal = 1;
	}

	if (streq(key, "en_address"))
	{
		val = [LUAgent canonicalEthernetAddress:val];
		freeVal = 1;
	}

	item = [self findItemWithKey:key value:val category:cat];
	if ((cat == LUCategoryBootp) && (item != nil))
	{
		if (streq(key, "ip_address"))
		{
			/* only return a directory if there is an en_address */
			if ([item valuesForKey:"en_address"] == NULL)
			{
				[item release];
				if (freeVal != 0) free(val);
				return nil;
			}

			[self preferBootpAddress:val key:key target:"en_address" dict:item];
		}
		else if (streq(key, "en_address"))
		{
			[self preferBootpAddress:val key:key target:"ip_address" dict:item];
		}
	}

	if (freeVal != 0) free(val);
	return item;
}

- (BOOL)inNetgroup:(char *)group
	host:(char *)host
	user:(char *)user
	domain:(char *)domain
	level:(int)level
{
	LUDictionary *g;
	int i, len;
	char **members;
	char *name;

	if (level > MaxNetgroupRecursion)
	{
		system_log(LOG_ERR, "netgroups nested more than %d levels",
			MaxNetgroupRecursion);
		return NO;
	}

	if (group == NULL) return NO;
	g = [self itemWithKey:"name" value:group category:LUCategoryNetgroup];
	if (g == nil) return NO;

	if (host != NULL)
	{
		name = host;
		members = [g valuesForKey:"hosts"];
	}
	else if (user != NULL)
	{
		name = user;
		members = [g valuesForKey:"users"];
	}
	else if (domain != NULL)
	{
		name = domain;
		members = [g valuesForKey:"domains"];
	}
	else
	{
		[g release];
		return NO;
	}

	if ((listIndex("*", members) != IndexNull) ||
		(listIndex(name, members) != IndexNull))
	{
		[g release];
		return YES;
	}

	members = [g valuesForKey:"netgroups"];
	len = [g countForKey:"netgroups"];
	for (i = 0; i < len; i++)
	{
		if ([self inNetgroup:members[i] host:host user:user domain:domain
			level:level+1])
		{
			[g release];
			return YES;
		}
	}

	[g release];
	return NO;
}

- (BOOL)inNetgroup:(char *)group
	host:(char *)host
	user:(char *)user
	domain:(char *)domain
{
	char **nameList;
	int i, len;
	BOOL yn;

	nameList = [self hostNameList:host];
	len = listLength(nameList);

	for (i = 0; i < len; i++)
	{
		yn = [self inNetgroup:group host:nameList[i] user:user domain:domain level:0];
		if (yn == YES)
		{
			freeList(nameList);
			return YES;
		}
	}

	freeList(nameList);
	return NO;
}

/*
 * Essentially the same as gethostbyname, but we continue
 * searching until we find a record with an ipv6_address attribute.
 */
- (LUDictionary *)ipv6NodeWithName:(char *)name wantv4:(BOOL)wantv4
{
	char **lookupOrder;
	const char *sname;
	const char *altkey;
	LUDictionary *item;
	LUAgent *agent;
	int i, len;
	struct timeval allStart;
	struct timeval sysStart;
	unsigned int sysTime = 0;
	unsigned int allTime;
	BOOL found;

	if (name == NULL) return nil;

	altkey = "namev6";
	if (wantv4) altkey = "namev46";

	if (statistics_enabled)
	{
		gettimeofday(&allStart, (struct timezone *)NULL);
		currentCall = "ipv6 node name";
	}

	lookupOrder = [self lookupOrderForCategory:LUCategoryHost];
	item = nil;
	len = listLength(lookupOrder);
	for (i = 0; i < len; i++)
	{
		agent = [self agentNamed:lookupOrder[i]];
		if (agent == nil) continue;
		sname = [agent shortName];

		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);
			currentAgent = agent;
			state = ServerStateQuerying;
		}

		item = nil;
		if (streq(sname, "Cache")) item = [agent itemWithKey:(char *)altkey value:name category:LUCategoryHost];
		else if (streq(sname, "DNS")) item = [agent itemWithKey:(char *)altkey value:name category:LUCategoryHost];
		else if (streq(sname, "NIL")) item = [agent itemWithKey:(char *)altkey value:name category:LUCategoryHost];
		else item = [agent itemWithKey:"name" value:name category:LUCategoryHost];

		if (statistics_enabled)
		{
			state = ServerStateActive;
			currentAgent = nil;
			sysTime = milliseconds_since(sysStart);
		}

		found = NO;
		if (item != nil)
		{
			/* Check for ipv6_address attribute */
			if ([item valueForKey:"ipv6_address"] == NULL)
			{
				[item release];
				item = nil;
			}
			else found = YES;
		}

		if (statistics_enabled) [self recordSearch:currentCall args:name infoSystem:sname time:sysTime hit:found];

		if (found)
		{
			if (statistics_enabled)
			{
				allTime = milliseconds_since(allStart);
				[self recordCall:currentCall args:name time:allTime hit:found];
				currentCall = NULL;
			}
			return [self stamp:item key:(char *)altkey agent:agent category:LUCategoryHost];
		}
	}

	if (statistics_enabled)
	{
		allTime = milliseconds_since(allStart);
		[self recordSearch:currentCall args:name infoSystem:"Failed" time:allTime hit:YES];
		[self recordCall:currentCall args:name time:allTime hit:NO];
		currentCall = NULL;
	}

	return nil;
}

- (LUDictionary *)ipv6NodeWithName:(char *)name
{
	return [self ipv6NodeWithName:name wantv4:YES];
}

- (LUDictionary *)serviceWithName:(char *)name
	protocol:(char *)prot
{
	char **lookupOrder;
	const char *sname;
	LUDictionary *item;
	LUAgent *agent;
	int i, len;
	struct timeval allStart;
	struct timeval sysStart;
	unsigned int sysTime;
	unsigned int allTime;
	char *scratch;

	if (name == NULL) return nil;

	if (statistics_enabled)
	{
		gettimeofday(&allStart, (struct timezone *)NULL);
		currentCall = "service name";
	}

	scratch = NULL;
	asprintf(&scratch, "service name %s%s%s", name, (prot == NULL) ? "" : "/", (prot == NULL) ? "" : prot);

	lookupOrder = [self lookupOrderForCategory:LUCategoryService];
	item = nil;
	len = listLength(lookupOrder);
	for (i = 0; i < len; i++)
	{
		agent = [self agentNamed:lookupOrder[i]];
		if (agent == nil) continue;
		sname = [agent shortName];

		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);
			currentAgent = agent;
			state = ServerStateQuerying;
		}

		item = [agent serviceWithName:name protocol:prot];

		if (statistics_enabled)
		{
			state = ServerStateActive;
			currentAgent = nil;
			sysTime = milliseconds_since(sysStart);
			[self recordSearch:currentCall args:scratch infoSystem:sname time:sysTime hit:(item != nil)];
		}

		if (item != nil)
		{
			if (statistics_enabled)
			{
				allTime = milliseconds_since(allStart);
				[self recordCall:currentCall args:scratch time:allTime hit:YES];
				currentCall = NULL;
			}

			if (scratch != NULL) free(scratch);
			return [self stamp:item key:"name" agent:agent category:LUCategoryService];
		}
	}

	if (statistics_enabled)
	{
		allTime = milliseconds_since(allStart);
		[self recordSearch:currentCall args:scratch infoSystem:"Failed" time:allTime hit:YES];
		[self recordCall:currentCall args:scratch time:allTime hit:NO];
		currentCall = NULL;
	}

	if (scratch != NULL) free(scratch);

	return nil;
}

- (LUDictionary *)serviceWithNumber:(int *)number
	protocol:(char *)prot
{
	char **lookupOrder;
	const char *sname;
	LUDictionary *item;
	LUAgent *agent;
	int i, len;
	struct timeval allStart;
	struct timeval sysStart;
	unsigned int sysTime;
	unsigned int allTime;
	char *scratch;

	if (number == NULL) return nil;
	if ((*number) == 0) return nil;

	scratch = NULL;
	asprintf(&scratch, "service number %u%s%s", *number, (prot == NULL) ? "" : "/", (prot == NULL) ? "" : prot);

	if (statistics_enabled)
	{
		gettimeofday(&allStart, (struct timezone *)NULL);
		currentCall = "service number";
	}

	lookupOrder = [self lookupOrderForCategory:LUCategoryService];
	item = nil;
	len = listLength(lookupOrder);
	for (i = 0; i < len; i++)
	{
		agent = [self agentNamed:lookupOrder[i]];
		if (agent == nil) continue;
		sname = [agent shortName];

		if (statistics_enabled)
		{
			gettimeofday(&sysStart, (struct timezone *)NULL);
			currentAgent = agent;
			state = ServerStateQuerying;
		}

		item = [agent serviceWithNumber:number protocol:prot];

		if (statistics_enabled)
		{
			state = ServerStateActive;
			currentAgent = nil;
			sysTime = milliseconds_since(sysStart);
			[self recordSearch:currentCall args:scratch infoSystem:sname time:sysTime hit:(item != nil)];
		}

		if (item != nil)
		{
			if (statistics_enabled)
			{
				allTime = milliseconds_since(allStart);
				[self recordCall:currentCall args:scratch time:allTime hit:YES];
				currentCall = NULL;
			}

			if (scratch != NULL) free(scratch);
			return [self stamp:item key:"number" agent:agent category:LUCategoryService];
		}
	}

	if (statistics_enabled)
	{
		allTime = milliseconds_since(allStart);
		[self recordSearch:currentCall args:scratch infoSystem:"Failed" time:allTime hit:YES];
		[self recordCall:currentCall args:scratch time:allTime hit:NO];
		currentCall = NULL;
	}

	if (scratch != NULL) free(scratch);

	return nil;
}

- (BOOL)isSecurityEnabledForOption:(char *)option
{
	/* Obsolete - not used by loginwindow any more */
	return NO;
}

- (BOOL)isNetwareEnabled
{
	/* Obsolete */
	return NO;
}

- (LUDictionary *)dns_proxy:(LUDictionary *)dict
{
	struct timeval dnsStart;
	unsigned int dnsTime;
	LUDictionary *item;
	DNSAgent *dns;
	char *desc;

	dns = (DNSAgent *)[self agentNamed:"DNS"];
	if (dns == nil) return nil;

	if (statistics_enabled)
	{
		gettimeofday(&dnsStart, (struct timezone *)NULL);
		currentAgent = dns;
		currentCall = "dns_proxy";
		state = ServerStateQuerying;
	}

	item = [dns dns_proxy:dict];

	if (statistics_enabled)
	{
		state = ServerStateActive;
		currentAgent = nil;
		dnsTime = milliseconds_since(dnsStart);
		desc = [dict description];
		[self recordSearch:currentCall args:desc infoSystem:[dns shortName] time:dnsTime hit:(item == nil)];
		if (desc != NULL) free(desc);
		currentCall = "NULL";
	}

	return item;
}


/*
 * getaddrinfo support
 * Input dict may contain the following
 *
 * name: nodename
 * service: servname
 * protocol: [IPPROTO_UNSPEC] | IPPROTO_UDP | IPPROTO_TCP
 * socktype: [SOCK_UNSPEC] | SOCK_DGRAM | SOCK_STREAM
 * family: [PF_UNSPEC] | PF_INET | PF_INET6
 * canonname: [0] | 1
 * passive: [0] | 1
 * numerichost: [0] | 1
 *
 * Output dictionary may contain the following
 * All values are encoded as strings.
 *
 * flags: unsigned long
 * family: unsigned long
 * socktype: unsigned long
 * protocol: unsigned long
 * port: unsigned long
 * address: char *
 * scopeid: unsigned long
 * canonname: char *
 */

static void
new_addrinfo(LUArray *res, uint32_t flags, uint32_t sock, uint32_t proto, uint32_t family, uint32_t port, char *addr, uint32_t scopeid, char *cname)
{
	LUDictionary *a;

	if ((scopeid == 0) && (addr != NULL) && (!strncasecmp(addr, "fe80:", 5)))
	{
		scopeid = atoi(addr+5);
	}

	a = [[LUDictionary alloc] init];

	[a setUnsignedLong:flags forKey:"flags"];
	[a setUnsignedLong:family forKey:"family"];
	[a setUnsignedLong:sock forKey:"socktype"];
	[a setUnsignedLong:proto forKey:"protocol"];
	[a setUnsignedLong:port forKey:"port"];
	[a setValue:addr forKey:"address"];
	if (family == PF_INET6) [a setUnsignedLong:scopeid forKey:"scopeid"];
	if (cname != NULL) [a setValue:cname forKey:"canonname"];

	[res addObject:a];
	[a release];
}

- (void)gaiPP:(char *)nodename port:(uint32_t)port protocol:(uint32_t)proto family:(uint32_t)family setcname:(int)setcname result:(LUArray *)res
{
	int wantv4, wantv6, socktype;
	uint32_t i, count;
	char **addrs, *cname;
	LUDictionary *item;

	socktype = SOCK_UNSPEC;
	if (proto == IPPROTO_UDP) socktype = SOCK_DGRAM;
	if (proto == IPPROTO_TCP) socktype = SOCK_STREAM;

	cname = NULL;

	wantv4 = 1;
	wantv6 = 1;
	if (family == PF_INET6) wantv4 = 0;
	if (family == PF_INET) wantv6 = 0;

	if (wantv4 != 0)
	{
		item = [self itemWithKey:"name" value:nodename category:LUCategoryHost];
		if (item != nil)
		{
			if ((setcname != 0) && (cname == NULL)) cname = copyString([item valueForKey:"name"]);

			addrs = [item valuesForKey:"ip_address"];
			count = listLength(addrs);
			for (i = 0; i < count; i++)
			{
				new_addrinfo(res, 0, socktype, proto, PF_INET, port, addrs[i], 0, NULL);
			}

			[item release];
		}
	}

	if (wantv6 != 0)
	{
		item = [self ipv6NodeWithName:nodename wantv4:NO];
		if (item != nil)
		{
			if ((setcname != 0) && (cname == NULL)) cname = copyString([item valueForKey:"name"]);
			addrs = [item valuesForKey:"ipv6_address"];
			count = listLength(addrs);
			for (i = 0; i < count; i++)
			{
				new_addrinfo(res, 0, socktype, proto, PF_INET6, port, addrs[i], 0, NULL);
			}

			[item release];
		}
	}

	/* Set cname in first result */
	if ((cname != NULL) && ([res count] != 0))
	{
		item = [res objectAtIndex:0];
		if ([item valueForKey:"canonname"] == NULL) [item setValue:cname forKey:"canonname"];
	}

	if (cname != NULL) free(cname);
}

- (LUArray *)gai_service:(char *)servname info:(LUDictionary *)dict
{
	uint32_t got_port, port, proto, family, socktype, setcname, passive, wantv4, wantv6, numericservice;
	char *loopv4, *loopv6;
	LUArray *res;
	LUDictionary *item;

	if (servname == NULL) return nil;

	proto = [dict intForKey:"protocol"];
	if (proto == 0) proto = IPPROTO_UNSPEC;

	socktype = [dict intForKey:"socktype"];
	if (socktype == 0) socktype = SOCK_UNSPEC;

	if (socktype == SOCK_DGRAM) proto = IPPROTO_UDP;
	if (socktype == SOCK_STREAM) proto = IPPROTO_TCP;

	family = [dict intForKey:"family"];
	if (family == 0) family = PF_UNSPEC;

	setcname = [dict intForKey:"canonname"];
	passive = [dict intForKey:"passive"];

	loopv4 = "127.0.0.1";
	loopv6 = "0:0:0:0:0:0:0:1";

	if (passive == 1)
	{
		loopv4 = "0.0.0.0";
		loopv6 = "0:0:0:0:0:0:0:0";
	}

	wantv4 = 1;
	wantv6 = 1;
	if (family == PF_INET6) wantv4 = 0;
	if (family == PF_INET) wantv6 = 0;

	res = [[LUArray alloc] init];

	port = 0;

	/* Deal with numericservice */
	numericservice = is_a_number(servname);
	if (numericservice != 0)
	{
		port = atoi(servname);

		if (wantv4 != 0)
		{
			if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_UDP))
			{
				new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET, port, loopv4, 0, NULL);
			}

			if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_TCP))
			{
				new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET, port, loopv4, 0, NULL);
			}
		}

		if (wantv6 != 0)
		{
			if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_UDP))
			{
				new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET6, port, loopv6, 0, NULL);
			}

			if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_TCP))
			{
				new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET6, port, loopv6, 0, NULL);
			}
		}

		if ([res count] == 0)
		{
			[res release];
			return NULL;
		}

		/* Set cname in first result */
		if ((setcname == 1) && ([[res objectAtIndex:0] valueForKey:"canonname"] == NULL))
		{
			[[res objectAtIndex:0] setValue:"localhost" forKey:"canonname"];
		}

		return res;
	}

	if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_UDP))
	{
		got_port = 0;
		item = [self serviceWithName:servname protocol:"udp"];
		if (item != nil)
		{
			port = [item intForKey:"port"];
			got_port = 1;
			[item release];
		}

		if (got_port != 0)
		{
			if (wantv4 != 0)
			{
				new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET, port, loopv4, 0, NULL);
			}

			if (wantv6 != 0)
			{
				new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET6, port, loopv6, 0, NULL);
			}
		}
	}

	if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_TCP))
	{
		got_port = 0;
		item = [self serviceWithName:servname protocol:"tcp"];
		if (item != nil)
		{
			port = [item intForKey:"port"];
			got_port = 1;
			[item release];
		}

		if (got_port != 0)
		{
			if (wantv4 != 0)
			{
				new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET, port, loopv4, 0, NULL);
			}

			if (wantv6 != 0)
			{
				new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET6, port, loopv6, 0, NULL);
			}
		}
	}

	if ([res count] == 0)
	{
		[res release];
		return nil;
	}

	/* Set cname in first result */
	if ((setcname == 1) && ([[res objectAtIndex:0] valueForKey:"canonname"] == NULL))
	{
		[[res objectAtIndex:0] setValue:"localhost" forKey:"canonname"];
	}

	return res;
}

- (LUArray *)gai_node:(char *)nodename port:(int)port info:(LUDictionary *)dict
{
	uint32_t family, setcname, numerichost, wantv4, wantv6, scopeid;
	uint32_t proto, socktype;
	int32_t i, count;
	LUArray *res;
	LUDictionary *item;
	char **addrs, *cname, *p;
	struct in_addr a4;
	struct in6_addr a6;
	char paddr[64];

	if (nodename == NULL) return nil;

	cname = NULL;

	proto = [dict intForKey:"protocol"];
	if (proto == 0) proto = IPPROTO_UNSPEC;

	socktype = [dict intForKey:"socktype"];
	if (socktype == 0) socktype = SOCK_UNSPEC;

	if (socktype == SOCK_DGRAM) proto = IPPROTO_UDP;
	if (socktype == SOCK_STREAM) proto = IPPROTO_TCP;

	family = [dict intForKey:"family"];
	if (family == 0) family = PF_UNSPEC;

	setcname = [dict intForKey:"canonname"];

	numerichost = inet_pton(AF_INET, nodename, &a4);
	if (numerichost != 0)
	{
		/* Bail out if the family isn't what was specified */
		if ((family != PF_INET) && (family != PF_UNSPEC)) return nil;
		family = PF_INET;
	}

	if (numerichost == 0)
	{
		numerichost = inet_pton(AF_INET6, nodename, &a6);
		if (numerichost != 0)
		{
			/* Bail out if the family isn't what was specified */
			if ((family != PF_INET6) && (family != PF_UNSPEC)) return nil;
			family = PF_INET6;
		}
	}

	/* V4 mapped and compat addresses are converted to plain V4 */
	if ((numerichost != 0) && (family == PF_INET6))
	{
		if ((IN6_IS_ADDR_V4MAPPED(&a6)) || (IN6_IS_ADDR_V4COMPAT(&a6)))
		{
			memcpy(&(a4.s_addr), &(a6.s6_addr[12]), 4);
			family = PF_INET;
		}
	}

	/* Bail out if nodename is not numeric but AI_NUMERICHOST was specified. */
	if ((numerichost == 0) && ([dict intForKey:"numerichost"] != 0)) return nil;

	wantv4 = 1;
	wantv6 = 1;
	if (family == PF_INET6) wantv4 = 0;
	if (family == PF_INET) wantv6 = 0;

	res = [[LUArray alloc] init];

	/* Deal with numerichost */
	if (numerichost != 0)
	{
		if (wantv4 != 0)
		{
			if (inet_ntop(AF_INET, &a4, paddr, 64) != NULL)
			{
				if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_UDP) || (proto == IPPROTO_TCP))
				{
					if (proto != IPPROTO_TCP) new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET, port, paddr, 0, NULL);
					if (proto != IPPROTO_UDP) new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET, port, paddr, 0, NULL);
				}
				else
				{
					new_addrinfo(res, 0, SOCK_UNSPEC, IPPROTO_UNSPEC, PF_INET, port, paddr, 0, NULL);
				}

				if (setcname != 0)
				{
					item = [self itemWithKey:"ip_address" value:paddr category:LUCategoryHost];
					if (item != nil) 
					{
						if (cname == NULL) cname = copyString([item valueForKey:"name"]);
						[item release];
					}
				}
			}
		}

		if (wantv6 != 0)
		{
			scopeid = 0;
			p = strrchr(nodename, '%');
			if (p != NULL) scopeid = if_nametoindex(p+1);

			if (inet_ntop(AF_INET6, &a6, paddr, 64) != NULL)
			{
				if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_UDP) || (proto == IPPROTO_TCP))
				{
					if (proto != IPPROTO_TCP) new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET6, port, paddr, scopeid, NULL);
					if (proto != IPPROTO_UDP) new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET6, port, paddr, scopeid, NULL);
				}
				else
				{
					new_addrinfo(res, 0, SOCK_UNSPEC, IPPROTO_UNSPEC, PF_INET6, port, paddr, 0, NULL);
				}

				if (setcname != 0)
				{
					item = [self itemWithKey:"ipv6_address" value:paddr category:LUCategoryHost];
					if (item != nil) 
					{
						if ((setcname != 0) && (cname == NULL)) cname = copyString([item valueForKey:"name"]);
						[item release];
					}
				}
			}
		}

		if ([res count] == 0)
		{
			[res release];
			return nil;
		}

		/* Set cname in first result */
		if (cname != NULL)
		{
			[[res objectAtIndex:0] setValue:cname forKey:"canonname"];
			free(cname);
		}

		return res;
	}

	if (wantv4 != 0)
	{
		item = [self itemWithKey:"name" value:nodename category:LUCategoryHost];
		if (item != nil)
		{
			if ((setcname != 0) && (cname == NULL)) cname = copyString([item valueForKey:"name"]);

			addrs = [item valuesForKey:"ip_address"];
			count = listLength(addrs);
			for (i = 0; i < count; i++)
			{
				if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_UDP) || (proto == IPPROTO_TCP))
				{
					if (proto != IPPROTO_TCP) new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET, port, addrs[i], 0, NULL);
					if (proto != IPPROTO_UDP) new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET, port, addrs[i], 0, NULL);
				}
				else
				{
					new_addrinfo(res, 0, SOCK_UNSPEC, IPPROTO_UNSPEC, PF_INET, port, addrs[i], 0, NULL);
				}
			}

			[item release];
		}
	}

	if (wantv6 != 0)
	{
		item = [self ipv6NodeWithName:nodename wantv4:NO];
		if (item != nil)
		{
			if ((setcname != 0) && (cname == NULL)) cname = copyString([item valueForKey:"name"]);
			addrs = [item valuesForKey:"ipv6_address"];
			count = listLength(addrs);
			for (i = 0; i < count; i++)
			{
				if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_UDP) || (proto == IPPROTO_TCP))
				{
					if (proto != IPPROTO_TCP) new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET6, port, addrs[i], 0, NULL);
					if (proto != IPPROTO_UDP) new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET6, port, addrs[i], 0, NULL);
				}
				else
				{
					new_addrinfo(res, 0, SOCK_UNSPEC, IPPROTO_UNSPEC, PF_INET6, port, addrs[i], 0, NULL);
				}
			}

			[item release];
		}
	}

	count = [res count];
	if (count == 0)
	{
		[res release];
		return nil;
	}

	/* Set cname in first result */
	if ((setcname != 0) && (cname != NULL) && ([[res objectAtIndex:0] valueForKey:"canonname"] == NULL))
	{
		[[res objectAtIndex:0] setValue:cname forKey:"canonname"];
		free(cname);
	}

	return res;
}

- (LUArray *)prioritySort:(LUArray *)l
{
	LUArray *out;
	uint32_t i, j, incount, outcount, inp, inw, outp, outw, x;
	LUDictionary *initem, *outitem;
	char *val;

	if (l == nil) return nil;

	out = [[LUArray alloc] init];
	incount = [l count];
	outcount = 0;

	for (i = 0; i < incount; i++)
	{
		initem = [l objectAtIndex:i];

		val = [initem valueForKey:"priority"];
		inp = (uint32_t)-1;
		if (val != NULL) inp = atoi(val);
		else [initem setValue:"-1" forKey:"priority"];

		val = [initem valueForKey:"weight"];
		inw = 0;
		if (val != NULL) inw = atoi(val);

		x = random();

		inw = (x % 10000) * x;
		val = NULL;
		asprintf(&val, "%u", inw);
		if (val != NULL) 
		{
			[initem setValue:val forKey:"weight"];
			free(val);
		}
	}

	for (i = 0; i < incount; i++)
	{
		initem = [l objectAtIndex:i];

		val = [initem valueForKey:"priority"];
		inp = (uint32_t)-1;
		if (val != NULL) inp = atoi(val);

		val = [initem valueForKey:"weight"];
		inw = (uint32_t)0;
		if (val != NULL) inw = atoi(val);

		for (j = 0; j < outcount; j++)
		{
			outitem = [out objectAtIndex:i];

			val = [outitem valueForKey:"priority"];
			outp = (uint32_t)-1;
			if (val != NULL) outp = atoi(val);

			val = [outitem valueForKey:"weight"];
			outw = (uint32_t)0;
			if (val != NULL) outw = atoi(val);

			if (inp < outp) break;
			if ((inp == outp) && (inw < outw)) break;
		}

		[out insertObject:initem atIndex:j];
		outcount++;
	}

	return out;
}

- (LUArray *)gai_node:(char *)nodename service:(char *)servname info:(LUDictionary *)dict
{
	uint32_t port, port_udp, port_tcp, proto, family, socktype, setcname, numerichost, numericservice, scopeid;
	uint32_t wantv4, wantv6, got_port, got_udp, got_tcp, j, len;
	int32_t i, count;
	LUArray *res, *all;
	LUDictionary *item, *pattern;
	char *cname, *str, **hosts, *p;
	struct in_addr a4;
	struct in6_addr a6;
	char paddr[64];

	if (nodename == NULL) return nil;
	if (servname == NULL) return nil;

	/* Deal with numericservice */
	numericservice = is_a_number(servname);
	if (numericservice)
	{
		port = atoi(servname);
		return [self gai_node:nodename port:port info:dict];
	}

	cname = NULL;
	port = 0;

	proto = [dict intForKey:"protocol"];
	if (proto == 0) proto = IPPROTO_UNSPEC;

	socktype = [dict intForKey:"socktype"];
	if (socktype == 0) socktype = SOCK_UNSPEC;

	if (socktype == SOCK_DGRAM) proto = IPPROTO_UDP;
	if (socktype == SOCK_STREAM) proto = IPPROTO_TCP;

	family = [dict intForKey:"family"];
	if (family == 0) family = PF_UNSPEC;

	setcname = [dict intForKey:"canonname"];

	numerichost = inet_pton(AF_INET, nodename, &a4);
	if (numerichost != 0)
	{
		/* Bail out if the family isn't what was specified */
		if ((family != PF_INET) && (family != PF_UNSPEC)) return nil;
		family = PF_INET;
	}

	if (numerichost == 0)
	{
		numerichost = inet_pton(AF_INET6, nodename, &a6);
		if (numerichost != 0)
		{
			/* Bail out if the family isn't what was specified */
			if ((family != PF_INET6) && (family != PF_UNSPEC)) return nil;
			family = PF_INET6;
		}
	}

	/* V4 mapped and compat addresses are converted to plain V4 */
	if ((numerichost != 0) && (family == PF_INET6))
	{
		if ((IN6_IS_ADDR_V4MAPPED(&a6)) || (IN6_IS_ADDR_V4COMPAT(&a6)))
		{
			memcpy(&(a4.s_addr), &(a6.s6_addr[12]), 4);
			family = PF_INET;
		}
	}

	/* Bail out if nodename is not numeric but AI_NUMERICHOST was specified. */
	if ((numerichost == 0) && ([dict intForKey:"numerichost"] != 0)) return nil;

	wantv4 = 1;
	wantv6 = 1;
	if (family == PF_INET6) wantv4 = 0;
	if (family == PF_INET) wantv6 = 0;

	/* Deal with numerichost */
	if (numerichost != 0)
	{
		res = [[LUArray alloc] init];

		if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_UDP))
		{
			got_port = 0;
			item = [self serviceWithName:servname protocol:"udp"];
			if (item != nil)
			{
				port = [item intForKey:"port"];
				got_port = 1;
				[item release];
			}

			if (got_port != 0)
			{
				if (wantv4 != 0)
				{
					if (inet_ntop(AF_INET, &a4, paddr, 64) != NULL)
					{
						new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET, port, paddr, 0, NULL);
						if (setcname != 0)
						{
							item = [self itemWithKey:"ip_address" value:paddr category:LUCategoryHost];
							if (item != nil) 
							{
								if (cname == NULL) cname = copyString([item valueForKey:"name"]);
								[item release];
							}
						}
					}
				}

				if (wantv6 != 0)
				{
					scopeid = 0;
					p = strrchr(nodename, '%');
					if (p != NULL) scopeid = if_nametoindex(p+1);

					if (inet_ntop(AF_INET6, &a6, paddr, 64) != NULL)
					{
						new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET6, port, paddr, scopeid, NULL);
						if (setcname != 0)
						{
							item = [self itemWithKey:"ipv6_address" value:paddr category:LUCategoryHost];
							if (item != nil) 
							{
								if ((setcname != 0) && (cname == NULL)) cname = copyString([item valueForKey:"name"]);
								[item release];
							}
						}
					}
				}
			}
		}

		if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_TCP))
		{
			got_port = 0;
			item = [self serviceWithName:servname protocol:"tcp"];
			if (item != nil)
			{
				port = [item intForKey:"port"];
				got_port = 1;
				[item release];
			}

			if (got_port != 0)
			{
				if (wantv4 != 0)
				{
					if (inet_ntop(AF_INET, &a4, paddr, 64) != NULL)
					{
						new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET, port, paddr, 0, NULL);
					}
				}

				if (wantv6 != 0)
				{
					scopeid = 0;
					p = strrchr(nodename, '%');
					if (p != NULL) scopeid = if_nametoindex(p+1);

					if (inet_ntop(AF_INET6, &a6, paddr, 64) != NULL)
					{
						new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET6, port, paddr, scopeid, NULL);
					}
				}
			}
		}

		if ([res count] == 0)
		{
			[res release];
			return nil;
		}

		/* Set cname in first result */
		if (cname != NULL)
		{
			item = [res objectAtIndex:0];
			if ([item valueForKey:"canonname"] == NULL) [item setValue:cname forKey:"canonname"];
		}

		if (cname != NULL) free(cname);
		return res;
	}

	/* First check for this particular host / service (e.g. DNS_SRV) */
	pattern = [[LUDictionary alloc] init];

	[pattern setValue:(char *)[LUAgent categoryName:LUCategoryHost] forKey:"_lookup_category"];
	[pattern setValue:"YES" forKey:"_lookup_single"];
	[pattern setValue:nodename forKey:"name"];

	[pattern setValue:servname forKey:"service"];
	if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_UDP)) [pattern setValue:"udp" forKey:"protocol"];
	else if (proto == IPPROTO_TCP) [pattern setValue:"tcp" forKey:"protocol"];

	all = [self query:pattern];

	if (proto == IPPROTO_UNSPEC)
	{
		[pattern setValue:"tcp" forKey:"protocol"];
		res = [self query:pattern];
		if (res != nil)
		{
			count = [res count];
			if ((count > 0) && (all == nil)) all = [[LUArray alloc] init];
			for (i = 0; i < count; i++) [all addObject:[res objectAtIndex:i]];
			[res release];
		}
	}

	[pattern release];

	res = [self prioritySort:all];
	[all release];
	all = res;

	res = [[LUArray alloc] init];

	count = [all count];
	for (i = 0; i < count; i++)
	{
		item = [all objectAtIndex:i];

		str = [item valueForKey:"port"];
		if (str == NULL) continue;

		port = atoi(str);

		str = [item valueForKey:"protocol"];
		if (str == NULL) continue;

		if (!strcasecmp(str, "udp")) proto = IPPROTO_UDP;
		else if (!strcasecmp(str, "tcp")) proto = IPPROTO_TCP;
		else continue;

		str = [item valueForKey:"target"];
		if (str == NULL) continue;

		[self gaiPP:str port:port protocol:proto family:family setcname:setcname result:res];
	}

	count = [res count];
	if (count > 0)
	{
		[all release];
		return res;
	}

	/* Special case for "smtp": collect mail_exchanger names */
	hosts = NULL;

	if (!strcasecmp(servname, "smtp"))
	{
		for (i = 0; i < count; i++)
		{
			item = [all objectAtIndex:i];

			str = [item valueForKey:"mail_exchanger"];
			if ((str != NULL) && (listIndex(str, hosts) == IndexNull))
			{
				hosts = appendString(str, hosts);
			}
		}
	}

	[all release];

	got_udp = 0;
	port_udp = 0;
	if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_UDP))
	{
		item = [self serviceWithName:servname protocol:"udp"];
		if (item != NULL)
		{
			port_udp = [item intForKey:"port"];
			got_udp = 1;
			[item release];
		}
	}

	got_tcp = 0;
	port_tcp = 0;
	if ((proto == IPPROTO_UNSPEC) || (proto == IPPROTO_TCP))
	{
		item = [self serviceWithName:servname protocol:"tcp"];
		if (item != nil)
		{
			port_tcp = [item intForKey:"port"];
			got_tcp = 1;
			[item release];
		}
	}

	if ((got_udp == 0) && (got_tcp == 0))
	{
		freeList(hosts);
		if ([res count] == 0)
		{
			[res release];
			return nil;
		}

		return res;
	}

	len = listLength(hosts);
	for (j = 0; j < len; j++)
	{
		if (got_udp != 0)
		{
			if (wantv4 != 0) [self gaiPP:hosts[j] port:port_udp protocol:IPPROTO_UDP family:PF_INET setcname:setcname result:res];
			if (wantv6 != 0) [self gaiPP:hosts[j] port:port_udp protocol:IPPROTO_UDP family:PF_INET6 setcname:setcname result:res];
		}

		if (got_tcp != 0)
		{
			if (wantv4 != 0) [self gaiPP:hosts[j] port:port_tcp protocol:IPPROTO_TCP family:PF_INET setcname:setcname result:res];
			if (wantv6 != 0) [self gaiPP:hosts[j] port:port_tcp protocol:IPPROTO_TCP family:PF_INET6 setcname:setcname result:res];
 		}
	}

	freeList(hosts);

	pattern = [[LUDictionary alloc] init];

	[pattern setValue:(char *)[LUAgent categoryName:LUCategoryHost] forKey:"_lookup_category"];
	[pattern setValue:"YES" forKey:"_lookup_single"];
	[pattern setValue:nodename forKey:"name"];

	all = [self query:pattern];

	[pattern release];

	cname = NULL;
	count = [all count];
	for (i = 0; i < count; i++)
	{
		item = [all objectAtIndex:i];
		if ((setcname != 0) && (cname == NULL)) cname = copyString([item valueForKey:"name"]);

		if (wantv4 != 0)
		{
			hosts = [item valuesForKey:"ip_address"];
			len = listLength(hosts);
			for (j = 0; j < len; j++)
			{
				if (got_udp != 0) new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET, port_udp, hosts[j], 0, NULL);
				if (got_tcp != 0) new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET, port_tcp, hosts[j], 0, NULL);
			}
		}

		if (wantv6 != 0)
		{
			hosts = [item valuesForKey:"ipv6_address"];
			len = listLength(hosts);
			for (j = 0; j < len; j++)
			{
				if (got_udp != 0) new_addrinfo(res, 0, SOCK_DGRAM, IPPROTO_UDP, PF_INET6, port_udp, hosts[j], 0, NULL);
				if (got_tcp != 0) new_addrinfo(res, 0, SOCK_STREAM, IPPROTO_TCP, PF_INET6, port_tcp, hosts[j], 0, NULL);
			}
		}
	}

	[all release];

	count = [res count];
	if (count == 0)
	{
		if (cname != NULL) free(cname);
		[res release];
		return nil;
	}

	/* Set cname in first result */
	if ((cname != NULL) && ([[res objectAtIndex:0] valueForKey:"canonname"] == NULL))
	{
		[[res objectAtIndex:0] setValue:cname forKey:"canonname"];
	}

	if (cname != NULL) free(cname);

	return res;
}

- (LUArray *)gai_base:(LUDictionary *)dict
{
	char *nodename, *servname;

	nodename = [dict valueForKey:"name"];
	servname = [dict valueForKey:"service"];

	if (nodename == NULL) return [self gai_service:servname info:dict];
	if (servname == NULL) return [self gai_node:nodename port:0 info:dict];
	return [self gai_node:nodename service:servname info:dict];
}

- (void)gai_async
{
	LUDictionary *dict;
	LUArray **res, *list;
	Thread *me;
	LUServer *s;

	me = [Thread currentThread];
	[me setState:ThreadStateActive];
	res = [me server];
	list = nil;

	dict = (LUDictionary *)[me data];

	s = [controller checkOutServer];
	list = [s gai_base:dict];
	[controller checkInServer:s];

	*res = list;

	/* Signal the fact that we've finished */
	[dict setNegative:YES];

	/*
	 * Wait for the "main" thread to tell us to clean up and exit.
	 * The main thread will have copied out our results if it wanted
	 * them.  We are responsible for releasing our result list and
	 * our input dict.
	 */
	[me setState:ThreadStateIdle];
	while (![me shouldTerminate])
	{
		[me sleep:1];
	}

	if (list != nil) [list release];
	[dict release];
	free(res);
	[me terminateSelf];
}

/*
 * Serial search
 */
- (LUArray *)gai_serial:(LUDictionary *)dict type:(uint32_t)search
{
	uint32_t i, count, wait, delta, family2;
	Thread *main_thread, *worker;
	LUArray *res, **res2;
	LUDictionary *dict2;
	struct timeval start;
	uint32_t status;

	if ((search == GAI_4) || (search == GAI_6))
	{
		family2 = [dict intForKey:"family"];
		if (family2 == PF_UNSPEC)
		{
			if (search == GAI_4) [dict setInt:PF_INET forKey:"family"];
			else [dict setInt:PF_INET6 forKey:"family"];
		}

		return [self gai_base:dict];
	}

	main_thread = [Thread currentThread];
	res = nil;

	if (search == GAI_S46)
	{
		[dict setInt:PF_INET forKey:"family"];
		family2 = PF_INET6;
	}
	else
	{
		[dict setInt:PF_INET6 forKey:"family"];
		family2 = PF_INET;
	}

	gettimeofday(&start, (struct timezone *)NULL);

	res = [self gai_base:dict];

	if (gai_wait == 0) return res;

	if (res == nil)
	{
		[dict setInt:family2 forKey:"family"];
		return [self gai_base:dict];
	}

	delta = milliseconds_since(start) + 1;
	wait = ((delta * gai_wait) + (WAIT_FOR_PARALLEL_REPLY - 1)) / WAIT_FOR_PARALLEL_REPLY;
	
	dict2 = [dict copy];
	[dict2 setInt:family2 forKey:"family"];

	worker = [[Thread alloc] init];
	[worker setName:"GAI SERIAL"];
	res2 = (LUArray **)malloc(sizeof(LUArray *));
	*res2 = nil;
	[worker setServer:res2];
	[worker setData:dict2];
	status = GAI_SEARCHING;

	[worker run:@selector(gai_async) context:self];

	/*
	 * Poll for results (checking isNegative), sleeping WAIT_FOR_PARALLEL_REPLY
	 * milliseconds each time through the polling loop.  The (gai_wait * delta) timeout
	 * for the second thread is also rounded up when we calculate the number of
	 * loop iterations to wait for more data.  This gives the second thread
	 * up to WAIT_FOR_PARALLEL_REPLY-1 extra milliseconds to complete.
	 */
	for (i = 0; i < wait; i++)
	{
		if ([dict isNegative]) break;
		[main_thread usleep:WAIT_FOR_PARALLEL_REPLY];
	}
	
	/* Merge results */
	if (*res2 != nil)
	{
		count = [*res2 count];
		if (res == nil) res = [[LUArray alloc] init];

		for (i = 0; i < count; i++)
		{
			[res addObject:[*res2 objectAtIndex:i]];
		}
	}

	[worker shouldTerminate:YES];

	return res;
}

/*
 * Parallel search for INET and INET6, with an adaptive
 * timeout for the second search to deliver results.
 *
 * We spin off threads to do independent searches for each address family.
 * The results are passed back here through res4 and res6.  The addresses
 * for these are passed to the threads using the "server" variable (kludge #1).
 * The search args (dict) is passed to the thread as its "data" variable
 * (only a half-kludge, #1.5).  The threads use the "isNegative" setting of
 * their dicts as a signal to inform this thread that they've finished
 * (kludge #2.5).  After that they sleep.  This thread signals them to exit
 * using shouldTerminate: so that we can copy out the data from res4 and res6.
 * That allows us to abandon the second threads if it is taking too long.
 * It will clean up after itself when it finishes its search.
 */
- (LUArray *)gai_parallel:(LUDictionary *)dict
{
	uint32_t i, count, wait, delta;
	Thread *main_thread, *worker4, *worker6;
	LUArray *res, **res4, **res6;
	LUDictionary *dict4, *dict6;
	struct timeval start;
	uint32_t status4, status6;

	main_thread = [Thread currentThread];
	res = nil;

	worker4 = [[Thread alloc] init];
	[worker4 setName:"GAI 4"];
	res4 = (LUArray **)malloc(sizeof(LUArray *));
	*res4 = nil;
	dict4 = [dict copy];
	[dict4 setInt:PF_INET forKey:"family"];
	[worker4 setServer:res4];
	[worker4 setData:dict4];
	status4 = GAI_SEARCHING;

	worker6 = [[Thread alloc] init];
	[worker6 setName:"GAI 6"];
	res6 = (LUArray **)malloc(sizeof(LUArray *));
	*res6 = nil;
	dict6 = [dict copy];
	[dict6 setInt:PF_INET6 forKey:"family"];
	[worker6 setServer:res6];
	[worker6 setData:dict6];
	status6 = GAI_SEARCHING;

	delta = 0;
	gettimeofday(&start, (struct timezone *)NULL);

	[worker4 run:@selector(gai_async) context:self];
	[worker6 run:@selector(gai_async) context:self];

	/*
	 * Now wait for data to appear.  When we get a positive result from either
	 * thread, we wait for a while to let the other thread return its results.
	 * The second thread gets an extra gai_wait * (time delta for first thread) to return
	 * an answer, then we give up.
	 *
	 * We poll for results (checking isNegative), sleeping WAIT_FOR_PARALLEL_REPLY
	 * milliseconds each time through the polling loop.  The (gai_wait * delta) timeout
	 * for the second thread is also rounded up when we calculate the number of
	 * loop iterations to wait for more data.  This gives the second thread
	 * up to WAIT_FOR_PARALLEL_REPLY-1 extra milliseconds to complete.
	 */
	wait = 0;
	forever
	{
		/* Avoid re-checking isNegative */
		if ((status4 == GAI_SEARCHING) && [dict4 isNegative])
		{
			if (*res4 == nil) status4 = GAI_NO_DATA;
			else status4 = GAI_GOT_DATA;
		}

		if ((status6 == GAI_SEARCHING) && [dict6 isNegative])
		{
			if (*res6 == nil) status6 = GAI_NO_DATA;
			else status6 = GAI_GOT_DATA;
		}

		if ((status4 != GAI_SEARCHING) && (status6 != GAI_SEARCHING)) break;

		if ((status4 == GAI_GOT_DATA) || (status6 == GAI_GOT_DATA))
		{
			if (gai_wait == 0) break;

			if (delta == 0)
			{
				delta = milliseconds_since(start) + 1;
				wait = ((delta * gai_wait) + (WAIT_FOR_PARALLEL_REPLY - 1)) / WAIT_FOR_PARALLEL_REPLY;
			}

			if (wait == 0) break;
			wait--;
		}

		[main_thread usleep:WAIT_FOR_PARALLEL_REPLY];
	}

	/* Merge results */
	if (status4 == GAI_GOT_DATA)
	{
		count = [*res4 count];
		if (res == nil) res = [[LUArray alloc] init];

		for (i = 0; i < count; i++)
		{
			[res addObject:[*res4 objectAtIndex:i]];
		}
	}

	if (status6 == GAI_GOT_DATA)
	{
		count = [*res6 count];
		if (res == nil) res = [[LUArray alloc] init];

		for (i = 0; i < count; i++)
		{
			[res addObject:[*res6 objectAtIndex:i]];
		}
	}

	[worker4 shouldTerminate:YES];
	[worker6 shouldTerminate:YES];

	return res;
}

/*
 * Entry point for getaddrinfo.
 *
 * There are 5 possible getaddrinfo searches:
 *
 * GAI_4    Only look for IPv4 addresses
 * GAI_6    Only look for IPv6 addresses
 * GAI_S46  Serial IPv4 then IPv6 (the default - set in lookupd.m)
 * GAI_S64  Serial IPv6 then IPv4
 * GAI_P    Parallel IPv4 & IPv6
 * 
 * If family is PF_INET, we use GAI_4.
 * If family is PF_INET6, we use GAI_6.
 * If family is PF_UNSPEC, we decide which search to use based on the caller's
 * setting of "parallel", which reflects the AI_PARALLEL flag in the API,
 * and the setting of the gai_pref config option.
 *
 * If the caller set the AI_PARALLEL bit, we use GAI_P.
 * Otherwise we use the setting of gai_pref.
 *
 * In the case of GAI_P, GAI_S46 and GAI_S64, gai_wait controls how long we'll
 * long we wait after we get the first reply.  We measure the time taken for the
 * first result (delta).  We wait for (gai_wait * delta) for the second reply.
 */
- (LUArray *)getaddrinfo:(LUDictionary *)dict
{
	uint32_t search, family, parallel;

	/* N.B. Hints are checked in Libinfo. */

	family = [dict intForKey:"family"];
	parallel = [dict intForKey:"parallel"];

	search = gai_pref;
	if (family == PF_INET) search = GAI_4;
	else if (family == PF_INET6) search = GAI_6;
	else if (parallel == 1) search = GAI_P;

	/* If gai_wait is zero, we simplify */
	if (gai_wait == 0)
	{
		if (search == GAI_S46) search = GAI_4;
		else if (search == GAI_S64) search = GAI_6;
	}

	if (search == GAI_P) return [self gai_parallel:dict];
	return [self gai_serial:dict type:search];
}

/*
 * getnameinfo support
 * Input dict may contain the following
 *
 * ip_address: node address
 * ipv6_address: node address
 * port: service number
 * protocol: [tcp] | udp
 * fqdn: [1] | 0
 * numerichost: [0] | 1
 * name_required: [0] | 1
 * numericserv: [0] | 1
 *
 * Output dictionary may contain the following
 * All values are encoded as strings.
 *
 * name: char *
 * service: char *
 */

 - (LUDictionary *)getnameinfo:(LUDictionary *)dict
{
	char *nodeaddr, *servnum, *p, *proto;
	LUDictionary *item, *dict2;
	uint32_t port, family, fqdn, numericserv, numerichost, namereq, gotdata;

	/* N.B. Args are checked in Libinfo. */

	gotdata = 0;

	family = PF_INET;
	nodeaddr = [dict valueForKey:"ip_address"];
	if (nodeaddr == NULL)
	{
		family = PF_INET6;
		nodeaddr = [dict valueForKey:"ipv6_address"];
	}
	if (nodeaddr == NULL) family = PF_UNSPEC;

	servnum = [dict valueForKey:"port"];

	if ((nodeaddr == NULL) && (servnum == NULL)) return nil;

	proto = "tcp";
	p = [dict valueForKey:"protocol"];
	if (p != NULL) proto = p;

	if (strcmp(proto, "tcp") && strcmp(proto, "udp")) return nil;

	fqdn = 1;
	p = [dict valueForKey:"fqdn"];
	if (p != NULL) fqdn = atoi(p);

	numerichost = 0;
	p = [dict valueForKey:"numerichost"];
	if (p != NULL) numerichost = atoi(p);

	numericserv = 0;
	p = [dict valueForKey:"numericserv"];
	if (p != NULL) numericserv = atoi(p);

	namereq = 0;
	p = [dict valueForKey:"name_required"];
	if (p != NULL) namereq = atoi(p);

	item = [[LUDictionary alloc] init];

	if (nodeaddr != NULL)
	{
		if (numerichost != 0) 
		{
			[item setValue:nodeaddr forKey:"name"];
			gotdata++;
		}
		else
		{
			dict2 = NULL;
			if (family == PF_INET)
			{
				dict2 = [self itemWithKey:"ip_address" value:nodeaddr category:LUCategoryHost];
			}
			else if (family == PF_INET6)
			{
				dict2 = [self itemWithKey:"ipv6_address" value:nodeaddr category:LUCategoryHost];
			}

			if (dict2 != NULL)
			{
				p = [dict2 valueForKey:"name"];
				if (p != NULL)
				{
					[item setValues:[dict2 valuesForKey:"name"] forKey:"name"];
					gotdata++;
				}
				[dict2 release];
			}
			else
			{
				if (namereq != 0)
				{
					[item release];
					return nil;
				}
			}
		}
	}

	if (servnum != NULL)
	{
		if (numericserv != 0) 
		{
			[item setValue:servnum forKey:"service"];
			gotdata++;
		}
		else
		{
			port = atoi(servnum);
			dict2 = [self serviceWithNumber:&port protocol:proto];
			if (dict2 != NULL)
			{
				p = [dict2 valueForKey:"name"];
				if (p != NULL)
				{
					[item setValues:[dict2 valuesForKey:"name"] forKey:"service"];
					gotdata++;
				}
				[dict2 release];
			}
		}
	}

	if (gotdata == 0)
	{
		[item release];
		return nil;
	}

	return item;
}

@end
