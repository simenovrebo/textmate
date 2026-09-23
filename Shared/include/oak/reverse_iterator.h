#ifndef OAK_REVERSE_ITERATOR_H_Q3VK8XW2
#define OAK_REVERSE_ITERATOR_H_Q3VK8XW2

#include <iterator>
#include <memory>
#include <type_traits>

namespace oak
{
	// Like std::reverse_iterator but safe for iterators that return a reference to data stored
	// in the iterator itself (e.g. oak::basic_tree_t, indexed_map_t, and utf8::iterator_t).
	//
	// std::reverse_iterator dereferences a temporary copy of the base iterator, so for such
	// iterators it returns a dangling reference. Here the decremented iterator is a member,
	// so references are valid as long as the reverse iterator is not changed or destroyed.

	template <typename _Iter>
	struct reverse_iterator
	{
		using iterator_type     = _Iter;
		using iterator_category = std::bidirectional_iterator_tag;
		using value_type        = typename std::iterator_traits<_Iter>::value_type;
		using difference_type   = typename std::iterator_traits<_Iter>::difference_type;
		using reference         = typename std::iterator_traits<_Iter>::reference;
		using pointer           = typename std::iterator_traits<_Iter>::pointer;

		explicit reverse_iterator (_Iter const& base) : _base(base), _current(base) { }

		_Iter base () const { return _base; }

		reference operator* () const
		{
			_current = std::prev(_base);
			return *_current;
		}

		auto operator-> () const
		{
			_current = std::prev(_base);
			if constexpr(std::is_pointer_v<_Iter>)
					return _current;
			else	return _current.operator->();
		}

		reverse_iterator& operator++ ()   { --_base; return *this; }
		reverse_iterator& operator-- ()   { ++_base; return *this; }
		reverse_iterator operator++ (int) { reverse_iterator tmp(*this); --_base; return tmp; }
		reverse_iterator operator-- (int) { reverse_iterator tmp(*this); ++_base; return tmp; }

		bool operator== (reverse_iterator const& rhs) const { return _base == rhs._base; }
		bool operator!= (reverse_iterator const& rhs) const { return _base != rhs._base; }

	private:
		_Iter _base;
		mutable _Iter _current; // Iterator that is dereferenced (one before _base), kept here so references into it remain valid
	};

} /* oak */

#endif /* end of include guard: OAK_REVERSE_ITERATOR_H_Q3VK8XW2 */
