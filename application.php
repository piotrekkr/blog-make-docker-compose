#!/usr/bin/env php
<?php
require __DIR__.'/vendor/autoload.php';

use Symfony\Component\Console\Application;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;

$application = new Application();

$application->register('hello')
->addArgument('username', InputArgument::REQUIRED)
->setCode(function (InputInterface $input, OutputInterface $output): int {
    $output->writeln("Hello {$input->getArgument('username')}!");

    return Command::SUCCESS;
});

$application->run();
