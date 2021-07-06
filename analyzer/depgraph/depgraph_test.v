module depgraph

fn test_depgraph() ? {
	mut course_book := Tree{}
	course_book.add({
		id: 'MAJOR-PHILOSOPHY', 
		dependencies: ['STAT-101', 'PHIL-102']
	})

	course_book.add({
		id: 'MAJOR-MATHS', 
		dependencies: ['STAT-101', 'CALC-102']
	})

	course_book.add({
		id: 'CALC-102', 
		dependencies: ['CALC-101']
	})

	course_book.add({
		id: 'CALC-101', 
		dependencies: ['STAT-100']
	})

	course_book.add({
		id: 'STAT-101', 
		dependencies: ['STAT-100']
	})

	course_book.add({ id: 'STAT-100' })

	course_book.add({
		id: 'PHIL-102',
		dependencies: ['PHIL-101']
	})

	course_book.add({ id: 'PHIL-101' })

	assert course_book.get_available_nodes('STAT-100') == ['CALC-101', 'STAT-101', 'PHIL-101']
	assert course_book.get_node('PHIL-102')?.get_all_dependencies() == ['PHIL-101']

	philo := course_book.get_node('MAJOR-PHILOSOPHY')?
	assert philo.dependencies == ['STAT-101', 'PHIL-102']
	assert philo.get_all_dependencies() == ['STAT-101', 'PHIL-102', 'STAT-100', 'PHIL-101']
	assert philo.get_all_dependencies('PHIL-101', 'STAT-100') == ['STAT-101', 'PHIL-102']
	assert course_book.get_node('MAJOR-MATHS')?.get_next_nodes('STAT-100') == ['CALC-101', 'STAT-101']
}