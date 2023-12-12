#!/usr/bin/env php
<?php
require __DIR__.'/vendor/autoload.php';

use Symfony\Component\Console\Application;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;

$application = new Application();

$application->register('generate-report')
->setCode(function (InputInterface $input, OutputInterface $output): int {
    $date = new DateTimeImmutable();
    $report = <<<EOT
    ======= REPORT =======
    DATE: {$date->format('Y-m-d')}
    TIME: {$date->format('H:i:s')}
    ...
    EOT;
    file_put_contents(getenv('APP_DATA_DIR').DIRECTORY_SEPARATOR.'report.txt', $report);
    $output->writeln('Report generated!');

    return Command::SUCCESS;
});

$application->run();
