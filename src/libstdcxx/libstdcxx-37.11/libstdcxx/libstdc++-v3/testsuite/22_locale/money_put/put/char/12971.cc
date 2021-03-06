// 2003-11-09 Paolo Carlini <pcarlini@suse.de>

// Copyright (C) 2003 Free Software Foundation
//
// This file is part of the GNU ISO C++ Library.  This library is free
// software; you can redistribute it and/or modify it under the
// terms of the GNU General Public License as published by the
// Free Software Foundation; either version 2, or (at your option)
// any later version.

// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License along
// with this library; see the file COPYING.  If not, write to the Free
// Software Foundation, 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301,
// USA.

// 22.2.6.2.1 money_put members

#include <locale>
#include <sstream>
#include <testsuite_hooks.h>

// libstdc++/12971
void test01()
{
  using namespace std;
  bool test __attribute__((unused)) = true;

  typedef ostreambuf_iterator<char> iterator_type;

  long double amount = 10.8L;
  
  // cache the money_put facet
  ostringstream oss;
  const money_put<char>& mon_put = use_facet<money_put<char> >(oss.getloc()); 

  iterator_type os_it01 = mon_put.put(oss.rdbuf(), true, oss, ' ', amount);
  string result = oss.str();
  VERIFY( result == "11" );
}

int main()
{
  test01();
  return 0;
}
